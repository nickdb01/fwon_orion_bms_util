import Foundation

final class LiveReader {
    private let transport: any DiagnosticTransport
    private var maximumCells: Int?
    private var layoutFromPopulation = false
    private var cooldown: [String: Date] = [:]
    init(transport: any DiagnosticTransport) { self.transport = transport }
    private func read(_ request: ReadRequest) throws -> WireReply {
        let key = request.body.hex
        if let until = cooldown[key], until > Date() { throw BMSError.io("Request temporarily unavailable; retrying later") }
        do { return try transport.exchange(request) }
        catch {
            if let error = error as? BMSError {
                if error == .disconnected { throw error }
                switch error {
                case .unsupported: cooldown[key] = .distantFuture
                default: cooldown[key] = Date().addingTimeInterval(30)
                }
            }
            throw error
        }
    }
    func sample(device: DeviceInfo, quantity: CellQuantity = .voltage) throws -> LiveSnapshot {
        var snapshot = LiveSnapshot(device: device)
        var timedOut = false
        let parameters: [ParameterPID] = [.packVoltage,.packCurrent,.packPower,.soc,.chargeLimit,.dischargeLimit,.highTemperature,.lowTemperature,.averageTemperature,.stateOfHealth,.lowCell,.highCell,.relayState,.limitReasons,.observedCapacity,.observedSOC]
        for pid in parameters {
            try Task.checkCancellation()
            if pid == .packPower, let firmware = device.firmware.flatMap({ FirmwareVersion(code:$0) }), let minimum = FirmwareVersion(code:"030700"), firmware < minimum {
                snapshot.readings.append(.init(key:pid.key,title:pid.title,unit:pid.unit,value:nil,acquiredAt:Date(),rawHex:"",note:"Requires firmware 3.7.0 or later"))
                continue
            }
            do {
                let reply = try read(.parameter(pid))
                snapshot.readings.append(.init(key: pid.key, title: pid.title, unit: pid.unit, value: try pid.decode(reply.payload), acquiredAt: Date(), rawHex: reply.bytes.hex))
            } catch {
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                if (error as? BMSError) == .timeout { timedOut = true }
                snapshot.readings.append(.init(key: pid.key, title: pid.title, unit: pid.unit, value: nil, acquiredAt: Date(), rawHex: "", note: error.localizedDescription))
            }
        }
        // The original utility obtains the channel layout from B0/00. Some
        // Junior firmware returns zero for F006 despite supplying valid banks.
        var populationReply: WireReply?
        do {
            populationReply = try read(.cellFlag(.populated))
            if let populationReply { snapshot.cellRaw.append(populationReply.bytes.hex) }
        } catch {
            try Task.checkCancellation()
            if (error as? BMSError) == .disconnected { throw error }
            snapshot.notes.append("Cell population: " + error.localizedDescription)
        }
        if maximumCells == nil {
            do {
                let reply = try read(.parameter(.maximumCells))
                let maxCount = Int(try ParameterPID.maximumCells.decode(reply.payload))
                if maxCount == 0, let count = populationReply?.payload.count, (1...2).contains(count) {
                    maximumCells = count * 8
                    layoutFromPopulation = true
                } else {
                    guard (1...16).contains(maxCount) else { throw BMSError.invalid("device reports \(maxCount) cells; this reader supports Junior units with 1–16") }
                    maximumCells = maxCount
                }
            } catch {
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                snapshot.notes.append("Cell layout: " + error.localizedDescription)
                let mayUseBitmap: Bool
                if case .invalid = error as? BMSError { mayUseBitmap = false }
                else { mayUseBitmap = true }
                if mayUseBitmap, let count = populationReply?.payload.count, (1...2).contains(count) {
                    maximumCells = count * 8
                    layoutFromPopulation = true
                }
            }
        }
        if layoutFromPopulation {
            snapshot.notes.append("Cell layout taken from the BMS population bitmap; the maximum-cell PID did not provide a count.")
        }
        if let maximumCells {
            var population: [Bool]?, balancing: [Bool]?
            if let populationReply {
                do { population = try LiveDecoding.flags(populationReply.payload, maximum: maximumCells) }
                catch { snapshot.notes.append("Cell population: " + error.localizedDescription) }
            }
            do {
                let reply = try read(.cellFlag(.balancing))
                balancing = try LiveDecoding.flags(reply.payload, maximum: maximumCells)
                snapshot.cellRaw.append(reply.bytes.hex)
            } catch {
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                snapshot.notes.append("Cell balancing: " + error.localizedDescription)
            }
            var values: [Int: Double] = [:], times: [Int: Date] = [:]
            for bank in 0..<((maximumCells + 11) / 12) {
                try Task.checkCancellation()
                do {
                    let reply = try read(.cells(quantity, UInt8(bank)))
                    let result = try quantity.decode(reply.payload, bank: UInt8(bank), maximum: maximumCells)
                    for (key, value) in result { values[key] = value; times[key] = Date() }
                    snapshot.cellRaw.append(reply.bytes.hex)
                } catch {
                    try Task.checkCancellation()
                    if (error as? BMSError) == .disconnected { throw error }
                    snapshot.notes.append("Cell bank \(bank + 1): " + error.localizedDescription)
                }
            }
            snapshot.cells = (1...maximumCells).map { number in
                CellReading(number: number, voltage: quantity == .voltage ? values[number] : nil, resistance: quantity == .resistance ? values[number] : nil, openVoltage: quantity == .openVoltage ? values[number] : nil, acquiredAt: times[number], populated: population?[number - 1], balancing: balancing?[number - 1])
            }
        }
        guard snapshot.readings.contains(where: { $0.value != nil }) || snapshot.cells.contains(where: { $0.value(for: quantity) != nil }) else {
            if timedOut { throw BMSError.timeout }
            throw BMSError.invalid("No live measurements decoded; diagnostic downloads remain available")
        }
        snapshot.finishedAt = Date()
        return snapshot
    }
}
