//
//  DetailedStatus.swift
//  OmniKit
//
//  Created by Pete Schwamb on 2/23/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation

// DetailedStatus is the PodInfo subtype 2 returned for a type 2 GetStatus command and
// is also returned on a pod fault for any command normally returning a StatusResponse
public struct DetailedStatus : PodInfo, Equatable {
    // CMD 1  2  3  4  5 6  7  8 9 10 1112 1314 1516 17 18 19 20 21 2223
    // DATA   0  1  2  3 4  5  6 7  8  910 1112 1314 15 16 17 18 19 2021
    // 02 16 02 0J 0K LLLL MM NNNN PP QQQQ RRRR SSSS TT UU VV WW 0X YYYY

    public let podInfoType: PodInfoResponseSubType = .detailedStatus
    public let podProgressStatus: PodProgressStatus
    public let deliveryStatus: DeliveryStatus
    public let bolusNotDelivered: Double
    public let lastProgrammingMessageSeqNum: UInt8 // updated by pod for 03, 08, $11, $19, $1A, $1C, $1E & $1F command messages
    public let totalInsulinDelivered: Double
    public let faultEventCode: FaultEventCode
    public let faultEventTimeSinceActivation: TimeInterval?
    public let reservoirLevel: Double?
    public let timeActive: TimeInterval
    public let unacknowledgedAlerts: AlertSet
    public let faultAccessingTables: Bool
    public let errorEventInfo: ErrorEventInfo?
    public let receiverLowGain: UInt8
    public let radioRSSI: UInt8
    public let previousPodProgressStatus: PodProgressStatus?
    // YYYY is uninitialized data for Eros
    public let data: Data
    
    public init(encodedData: Data) throws {
        guard encodedData.count >= 21 else {
            throw MessageBlockError.notEnoughData
        }
        
        guard PodProgressStatus(rawValue: encodedData[1]) != nil else {
            throw MessageError.unknownValue(value: encodedData[1], typeDescription: "PodProgressStatus")
        }
        self.podProgressStatus = PodProgressStatus(rawValue: encodedData[1])!
        
        self.deliveryStatus = DeliveryStatus(rawValue: encodedData[2] & 0xf)!
        
        self.bolusNotDelivered = Pod.pulseSize * Double((Int(encodedData[3] & 0x3) << 8) | Int(encodedData[4]))
        
        self.lastProgrammingMessageSeqNum = encodedData[5]
        
        self.totalInsulinDelivered = Pod.pulseSize * Double(encodedData[6...7].toBigEndian(UInt16.self))
        
        self.faultEventCode = FaultEventCode(rawValue: encodedData[8])
        
        let minutesSinceActivation = encodedData[9...10].toBigEndian(UInt16.self)
        if minutesSinceActivation != 0xffff {
            self.faultEventTimeSinceActivation = TimeInterval(minutes: Double(minutesSinceActivation))
        } else {
            self.faultEventTimeSinceActivation = nil
        }
        
        let reservoirValue = Double((Int(encodedData[11] & 0x3) << 8) + Int(encodedData[12])) * Pod.pulseSize
        
        if reservoirValue <= Pod.maximumReservoirReading {
            self.reservoirLevel = reservoirValue
        } else {
            self.reservoirLevel =  nil
        }
        
        self.timeActive = TimeInterval(minutes: Double(encodedData[13...14].toBigEndian(UInt16.self)))
        
        self.unacknowledgedAlerts =  AlertSet(rawValue: encodedData[15])
        
        self.faultAccessingTables = (encodedData[16] & 2) != 0
        
        if encodedData[17] == 0x00 {
           self.errorEventInfo = nil // this byte is not valid (no fault has occurred)
        } else {
            self.errorEventInfo = ErrorEventInfo(rawValue: encodedData[17])
        }
        
        self.receiverLowGain = UInt8(encodedData[18] >> 6)
        self.radioRSSI =  UInt8(encodedData[18] & 0x3F)
        
        if encodedData[19] == 0xFF {
            self.previousPodProgressStatus = nil // this byte is not valid (no fault has occurred)
        } else {
            self.previousPodProgressStatus = PodProgressStatus(rawValue: encodedData[19] & 0xF)!
        }
        
        self.data = Data(encodedData)
    }

    public var isFaulted: Bool {
        return faultEventCode.faultType != .noFaults || podProgressStatus == .activationTimeExceeded
    }

    // Returns an appropropriate PDM style Ref string for the Detailed Status.
    // For most types, Ref: TT-VVVHH-IIIRR-FFF computed as {20|19|18|17|16|15|14|07|01}-{VV}{SSSS/60}-{NNNN/20}{RRRR/20}-PP
    public var pdmRef: String? {
        let refStr = LocalizedString("Ref", comment: "PDM style 'Ref' string")
        let TT: UInt8
        var VVV: UInt8 = data[17] // default value, can be changed
        let HH: UInt8 = UInt8(timeActive.hours)
        let III: UInt8 = UInt8(totalInsulinDelivered)
        let RR: UInt8 = self.reservoirLevel != nil ? UInt8(self.reservoirLevel!) : 51 // 51 is value for 50+
        var FFF: UInt8 = faultEventCode.rawValue // defaut value, can bew changed

        switch faultEventCode.faultType {
        case .noFaults:
            return nil
        case .failedFlashErase ,.failedFlashStore, .tableCorruptionBasalSubcommand, .corruptionByte720, .corruptionInWord129, .disableFlashSecurityFailed:
            // Ref: 01-VVVHH-IIIRR-FFF
            TT = 01         // RAM Ref type
        case .badTimerVariableState, .problemCalibrateTimer, .rtcInterruptHandlerUnexpectedCall, .trimICSTooCloseTo0x1FF,
          .problemFindingBestTrimValue, .badSetTPM1MultiCasesValue:
            // Ref: 07-VVVHH-IIIRR-FFF
            TT = 07         // Clock Ref type
        case .insulinDeliveryCommandError:
            // Ref: 11-144-0018-0049, this fault is treated as a PDM fault with an alternate Ref format
            return String(format: "%@:\u{00a0}11-144-0018-00049", refStr) // all fixed values for this fault
        case .reservoirEmpty:
            // Ref: 14-VVVHH-IIIRR-FFF
            TT = 14         // PumpVolume Ref type
        case .autoOff0, .autoOff1, .autoOff2, .autoOff3, .autoOff4, .autoOff5, .autoOff6, .autoOff7:
            // Ref: 15-VVVHH-IIIRR-FFF
            TT = 15         // PumpAutoOff Ref type
        case .exceededMaximumPodLife80Hrs:
            // Ref: 16-VVVHH-IIIRR-FFF
            TT = 16         // PumpExpired Ref type
        case .occluded:
            // Ref: 17-000HH-IIIRR-000
            TT = 17         // PumpOcclusion Ref type
            VVV = 0         // no VVV value for an occlusion fault
            FFF = 0         // no FFF value for an occlusion fault
        case .bleTimeout, .bleInitiated, .bleUnkAlarm, .bleIaas, .crcFailure, .bleWdPingTimeout, .bleExcessiveResets, .bleNakError, .bleReqHighTimeout, .bleUnknownResp, .bleReqStuckHigh, .bleStateMachine1, .bleStateMachine2, .bleArbLost, .bleEr48DualNack, .bleQnExceedMaxRetry, .bleQnCritVarFail:
            // Ref: 20-VVVHH-IIIRR-FFF
            TT = 20         // PumpCommunications Ref type
        default:
            // Ref: 19-VVVHH-IIIRR-FFF
            TT = 19         // PumpError Ref type
        }

        return String(format: "%@:\u{00a0}%02d-%03d%02d-%03d%02d-%03d", refStr, TT, VVV, HH, III, RR, FFF)
    }
}

extension DetailedStatus: CustomDebugStringConvertible {
    public typealias RawValue = Data
    public var debugDescription: String {
        return [
            "## DetailedStatus",
            "* rawHex: \(data.hexadecimalString)",
            "* podProgressStatus: \(podProgressStatus)",
            "* deliveryStatus: \(deliveryStatus.description)",
            "* bolusNotDelivered: \(bolusNotDelivered.twoDecimals) U",
            "* lastProgrammingMessageSeqNum: \(lastProgrammingMessageSeqNum)",
            "* totalInsulinDelivered: \(totalInsulinDelivered.twoDecimals) U",
            "* faultEventCode: \(faultEventCode.description)",
            "* faultEventTimeSinceActivation: \(faultEventTimeSinceActivation?.stringValue ?? "none")",
            "* reservoirLevel: \(reservoirLevel?.twoDecimals ?? "50+") U",
            "* timeActive: \(timeActive.stringValue)",
            "* unacknowledgedAlerts: \(unacknowledgedAlerts)",
            "* faultAccessingTables: \(faultAccessingTables)",
            "* errorEventInfo: \(errorEventInfo?.description ?? "NA")",
            "* receiverLowGain: \(receiverLowGain)",
            "* radioRSSI: \(radioRSSI)",
            "* previousPodProgressStatus: \(previousPodProgressStatus?.description ?? "NA")",
            "",
            ].joined(separator: "\n")
    }
}

extension DetailedStatus: RawRepresentable {
    public init?(rawValue: Data) {
        do {
            try self.init(encodedData: rawValue)
        } catch {
            return nil
        }
    }
    
    public var rawValue: Data {
        return data
    }
}

extension TimeInterval {
    var stringValue: String {
        let totalSeconds = self
        let minutes = Int(totalSeconds / 60) % 60
        let hours = Int(totalSeconds / 3600) - (Int(self / 3600)/24 * 24)
        let days = Int((totalSeconds / 3600) / 24)
        var pluralFormOfDays = "days"
        if days == 1 {
            pluralFormOfDays = "day"
        }
        let timeComponent = String(format: "%02d:%02d", hours, minutes)
        if days > 0 {
            return String(format: "%d \(pluralFormOfDays) plus %@", days, timeComponent)
        } else {
            return timeComponent
        }
    }
}

extension Double {
    var twoDecimals: String {
        let reservoirLevel = self
        return String(format: "%.2f", reservoirLevel)
    }
}

// Type for the ErrorEventInfo VV byte if valid
//    a: insulin state table corruption found during error logging
//   bb: internal 2-bit occlusion type
//    c: immediate bolus in progress during error
// dddd: Pod Progress at time of first logged fault event
//
public struct ErrorEventInfo: CustomStringConvertible, Equatable {
    let rawValue: UInt8
    let insulinStateTableCorruption: Bool // 'a' bit
    let occlusionType: Int // 'bb' 2-bit occlusion type
    let immediateBolusInProgress: Bool // 'c' bit
    let podProgressStatus: PodProgressStatus // 'dddd' bits

    public var errorEventInfo: ErrorEventInfo? {
        return ErrorEventInfo(rawValue: rawValue)
    }

    public var description: String {
        let hexString = String(format: "%02X", rawValue)
        return [
            "rawValue: 0x\(hexString)",
            "insulinStateTableCorruption: \(insulinStateTableCorruption)",
            "occlusionType: \(occlusionType)",
            "immediateBolusInProgress: \(immediateBolusInProgress)",
            "podProgressStatus: \(podProgressStatus)",
            ].joined(separator: ", ")
    }

    init(rawValue: UInt8)  {
        self.rawValue = rawValue
        self.insulinStateTableCorruption = (rawValue & 0x80) != 0
        self.occlusionType = Int((rawValue & 0x60) >> 5)
        self.immediateBolusInProgress = (rawValue & 0x10) != 0
        self.podProgressStatus = PodProgressStatus(rawValue: rawValue & 0xF)!
    }
}
