// keyrestore.swift — recovery utility.
//
// Clears any `UserKeyMapping` another tool (or an older MagMIDI build) may have
// left on the MAD60's HID event services, which would make its keys dead.
//
// This only ever *removes* mappings: it writes an empty array. It deliberately
// does not install mappings, because bulk writes to the HID event stack are not
// safe to do casually.
//
// Usage: keyrestore

import Foundation
import IOKit

let VENDOR = 0x373B
let PRODUCT = 0x105D

setvbuf(stdout, nil, _IONBF, 0)

var iterator: io_iterator_t = 0
guard let matching = IOServiceMatching("IOHIDEventService") as NSMutableDictionary? else { exit(1) }
matching["VendorID"] = VENDOR
matching["ProductID"] = PRODUCT
matching["PrimaryUsagePage"] = 0x01
guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
    print("could not query IOHIDEventService")
    exit(1)
}
defer { IOObjectRelease(iterator) }

var count = 0
while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let dictionary = properties?.takeRetainedValue() as? [String: Any],
       let existing = dictionary["UserKeyMapping"] as? [[String: Any]], !existing.isEmpty {
        let result = IORegistryEntrySetCFProperty(service, "UserKeyMapping" as CFString, [] as CFArray)
        print("cleared \(existing.count) mapping(s) -> \(result == KERN_SUCCESS ? "ok" : "error \(result)")")
        count += 1
    }
}
print(count == 0 ? "nothing to restore — no key mapping present" : "restored \(count) service(s)")
