//
//  MachOBuilder.swift
//  TrollFools
//
//  Created by Antigravity on 2025/2/25.
//

import Foundation

/// Generates a minimal arm64 + arm64e FAT Mach-O dylib at runtime.
/// The binary does nothing — its purpose is to carry LC_LOAD_DYLIB load commands
/// injected by `insert_dylib` later.
enum MachOBuilder {
    // MARK: - Constants

    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE

    private static let CPU_TYPE_ARM64: UInt32 = 0x0100000C     // CPU_TYPE_ARM | CPU_ARCH_ABI64
    private static let CPU_SUBTYPE_ARM64_ALL: UInt32 = 0x00000000
    private static let CPU_SUBTYPE_ARM64E: UInt32 = 0x00000002

    private static let MH_DYLIB: UInt32 = 6
    private static let MH_TWOLEVEL: UInt32 = 0x80
    private static let MH_NO_REEXPORTED_DYLIBS: UInt32 = 0x100000
    private static let MH_PIE: UInt32 = 0x200000

    // Load command types
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_ID_DYLIB: UInt32 = 0x0D
    private static let LC_SYMTAB: UInt32 = 0x02
    private static let LC_DYSYMTAB: UInt32 = 0x0B
    private static let LC_UUID: UInt32 = 0x1B
    private static let LC_BUILD_VERSION: UInt32 = 0x32

    // Build version constants
    private static let PLATFORM_IOS: UInt32 = 2
    private static let TOOL_LD: UInt32 = 3

    // Page size for arm64
    private static let PAGE_SIZE: Int = 0x4000  // 16384

    // MARK: - Public

    /// Generate a FAT Mach-O dylib containing arm64 and arm64e slices.
    /// - Parameter installName: The install name for the dylib (e.g., "@rpath/TrollFoolsDummy.framework/TrollFoolsDummy")
    /// - Returns: The FAT Mach-O dylib as `Data`
    static func buildFATDylib(installName: String) -> Data {
        let arm64Slice = buildSlice(
            cpuSubtype: CPU_SUBTYPE_ARM64_ALL,
            installName: installName
        )
        let arm64eSlice = buildSlice(
            cpuSubtype: CPU_SUBTYPE_ARM64E,
            installName: installName
        )

        // Align slices to page boundaries
        let headerSize = 8 + 20 * 2  // fat_header (8) + 2 * fat_arch (20 each)
        let firstSliceOffset = alignTo(headerSize, PAGE_SIZE)
        let secondSliceOffset = alignTo(firstSliceOffset + arm64Slice.count, PAGE_SIZE)

        var data = Data()

        // FAT header (big-endian)
        appendBigEndian(&data, FAT_MAGIC)
        appendBigEndian(&data, UInt32(2))  // nfat_arch = 2

        // fat_arch #1: arm64
        appendBigEndian(&data, CPU_TYPE_ARM64)
        appendBigEndian(&data, CPU_SUBTYPE_ARM64_ALL)
        appendBigEndian(&data, UInt32(firstSliceOffset))
        appendBigEndian(&data, UInt32(arm64Slice.count))
        appendBigEndian(&data, UInt32(14))  // align = 2^14 = 16384

        // fat_arch #2: arm64e
        appendBigEndian(&data, CPU_TYPE_ARM64)
        appendBigEndian(&data, CPU_SUBTYPE_ARM64E)
        appendBigEndian(&data, UInt32(secondSliceOffset))
        appendBigEndian(&data, UInt32(arm64eSlice.count))
        appendBigEndian(&data, UInt32(14))  // align = 2^14 = 16384

        // Pad to first slice offset
        data.append(Data(count: firstSliceOffset - data.count))
        data.append(arm64Slice)

        // Pad to second slice offset
        data.append(Data(count: secondSliceOffset - data.count))
        data.append(arm64eSlice)

        return data
    }

    // MARK: - Private: Slice Builder

    /// Build a single arm64 Mach-O dylib slice.
    private static func buildSlice(cpuSubtype: UInt32, installName: String) -> Data {
        // We'll build the Mach-O in segments:
        // 1. Header + Load Commands (padded to PAGE_SIZE to leave room for insert_dylib)
        // 2. __TEXT segment (contains __text section with a single `ret` instruction)
        // 3. __LINKEDIT segment (contains minimal symtab + strtab)

        let installNameData = installName.utf8CString
        let installNameSize = installNameData.count

        // Pre-calculate sizes
        let headerSize = 32  // mach_header_64

        // Load commands we'll emit:
        // 1. LC_SEGMENT_64 __PAGEZERO (for dylib, vmaddr=0 vmsize=0)
        //    Actually dylibs don't need __PAGEZERO, skip it.
        // 1. LC_SEGMENT_64 __TEXT
        // 2. LC_SEGMENT_64 __LINKEDIT
        // 3. LC_ID_DYLIB
        // 4. LC_SYMTAB
        // 5. LC_DYSYMTAB
        // 6. LC_UUID
        // 7. LC_BUILD_VERSION

        let segmentCmdSize = 72      // segment_command_64 without sections
        let sectionSize = 80         // section_64
        let textSegCmdSize = segmentCmdSize + sectionSize  // __TEXT with one __text section
        let linkeditSegCmdSize = segmentCmdSize              // __LINKEDIT (no sections)

        let idDylibCmdSize = alignTo(24 + installNameSize, 8)  // dylib_command + name string, aligned to 8
        let symtabCmdSize = 24       // symtab_command
        let dysymtabCmdSize = 80     // dysymtab_command
        let uuidCmdSize = 24         // uuid_command
        let buildVersionCmdSize = 32 // build_version_command + 1 build_tool_version

        let totalLoadCommandsSize = textSegCmdSize + linkeditSegCmdSize + idDylibCmdSize +
            symtabCmdSize + dysymtabCmdSize + uuidCmdSize + buildVersionCmdSize
        let ncmds: UInt32 = 7

        // __TEXT segment starts at 0, spans the first page
        let textSegOffset = 0
        let textSegSize = PAGE_SIZE  // one full page

        // The actual code (__text section) goes near the end of the first page
        let textSectionOffset = PAGE_SIZE - 4  // just 4 bytes for `ret`
        let textSectionSize = 4

        // Minimal symtab: 1 entry with empty nlist + string table " \0"
        let nlistSize = 16  // nlist_64
        let strtabData: [UInt8] = [0x20, 0x00]  // " \0"
        let symtabOffset = textSegSize
        let strtabOffset = symtabOffset + nlistSize

        // __LINKEDIT segment
        let linkeditOffset = textSegSize
        let linkeditSize = alignTo(nlistSize + strtabData.count, 8)

        let totalFileSize = textSegSize + linkeditSize

        // Start building
        var data = Data()

        // === mach_header_64 ===
        appendLE(&data, MH_MAGIC_64)
        appendLE(&data, CPU_TYPE_ARM64)
        appendLE(&data, cpuSubtype)
        appendLE(&data, MH_DYLIB)
        appendLE(&data, ncmds)
        appendLE(&data, UInt32(totalLoadCommandsSize))
        appendLE(&data, MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS | MH_PIE)
        appendLE(&data, UInt32(0))  // reserved

        // === LC_SEGMENT_64 __TEXT ===
        appendLE(&data, LC_SEGMENT_64)
        appendLE(&data, UInt32(textSegCmdSize))
        appendSegName(&data, "__TEXT")
        appendLE(&data, UInt64(0))                        // vmaddr
        appendLE(&data, UInt64(textSegSize))              // vmsize
        appendLE(&data, UInt64(textSegOffset))            // fileoff
        appendLE(&data, UInt64(textSegSize))              // filesize
        appendLE(&data, UInt32(5))                        // maxprot: VM_PROT_READ | VM_PROT_EXECUTE
        appendLE(&data, UInt32(5))                        // initprot
        appendLE(&data, UInt32(1))                        // nsects
        appendLE(&data, UInt32(0))                        // flags

        // section_64: __text
        appendSectName(&data, "__text")
        appendSegName(&data, "__TEXT")
        appendLE(&data, UInt64(textSectionOffset))        // addr (= offset since segment vmaddr is 0)
        appendLE(&data, UInt64(textSectionSize))          // size
        appendLE(&data, UInt32(textSectionOffset))        // offset
        appendLE(&data, UInt32(2))                        // align: 2^2 = 4
        appendLE(&data, UInt32(0))                        // reloff
        appendLE(&data, UInt32(0))                        // nreloc
        appendLE(&data, UInt32(0x80000400))               // flags: S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
        appendLE(&data, UInt32(0))                        // reserved1
        appendLE(&data, UInt32(0))                        // reserved2
        appendLE(&data, UInt32(0))                        // reserved3

        // === LC_SEGMENT_64 __LINKEDIT ===
        appendLE(&data, LC_SEGMENT_64)
        appendLE(&data, UInt32(linkeditSegCmdSize))
        appendSegName(&data, "__LINKEDIT")
        appendLE(&data, UInt64(linkeditOffset))           // vmaddr
        appendLE(&data, UInt64(alignTo(linkeditSize, PAGE_SIZE)))  // vmsize (page aligned)
        appendLE(&data, UInt64(linkeditOffset))           // fileoff
        appendLE(&data, UInt64(linkeditSize))             // filesize
        appendLE(&data, UInt32(1))                        // maxprot: VM_PROT_READ
        appendLE(&data, UInt32(1))                        // initprot
        appendLE(&data, UInt32(0))                        // nsects
        appendLE(&data, UInt32(0))                        // flags

        // === LC_ID_DYLIB ===
        appendLE(&data, LC_ID_DYLIB)
        appendLE(&data, UInt32(idDylibCmdSize))
        appendLE(&data, UInt32(24))   // name offset (right after the cmd header)
        appendLE(&data, UInt32(0))    // timestamp
        appendLE(&data, UInt32(0x00010000))  // current_version: 1.0.0
        appendLE(&data, UInt32(0x00010000))  // compat_version: 1.0.0
        // name string
        let nameBytes = Array(installName.utf8) + [0]
        data.append(contentsOf: nameBytes)
        // pad to alignment
        let namePadding = idDylibCmdSize - 24 - nameBytes.count
        if namePadding > 0 {
            data.append(Data(count: namePadding))
        }

        // === LC_SYMTAB ===
        appendLE(&data, LC_SYMTAB)
        appendLE(&data, UInt32(symtabCmdSize))
        appendLE(&data, UInt32(symtabOffset))    // symoff
        appendLE(&data, UInt32(1))               // nsyms
        appendLE(&data, UInt32(strtabOffset))    // stroff
        appendLE(&data, UInt32(strtabData.count))  // strsize

        // === LC_DYSYMTAB ===
        appendLE(&data, LC_DYSYMTAB)
        appendLE(&data, UInt32(dysymtabCmdSize))
        // All fields zero except nlocalsym
        appendLE(&data, UInt32(0))   // ilocalsym
        appendLE(&data, UInt32(1))   // nlocalsym
        appendLE(&data, UInt32(1))   // iextdefsym
        appendLE(&data, UInt32(0))   // nextdefsym
        appendLE(&data, UInt32(1))   // iundefsym
        appendLE(&data, UInt32(0))   // nundefsym
        appendLE(&data, UInt32(0))   // tocoff
        appendLE(&data, UInt32(0))   // ntoc
        appendLE(&data, UInt32(0))   // modtaboff
        appendLE(&data, UInt32(0))   // nmodtab
        appendLE(&data, UInt32(0))   // extrefsymoff
        appendLE(&data, UInt32(0))   // nextrefsyms
        appendLE(&data, UInt32(0))   // indirectsymoff
        appendLE(&data, UInt32(0))   // nindirectsyms

        // === LC_UUID ===
        appendLE(&data, LC_UUID)
        appendLE(&data, UInt32(uuidCmdSize))
        // Generate a random UUID
        let uuid = UUID()
        var uuidBytes = uuid.uuid
        data.append(Data(bytes: &uuidBytes, count: 16))

        // === LC_BUILD_VERSION ===
        appendLE(&data, LC_BUILD_VERSION)
        appendLE(&data, UInt32(buildVersionCmdSize))
        appendLE(&data, PLATFORM_IOS)    // platform
        appendLE(&data, UInt32(0x000E0000))  // minos: 14.0.0
        appendLE(&data, UInt32(0x000E0000))  // sdk: 14.0.0
        appendLE(&data, UInt32(1))           // ntools
        // build_tool_version
        appendLE(&data, TOOL_LD)
        appendLE(&data, UInt32(0x03410000))  // ld version

        // Pad header area to fill __TEXT segment (leaves room for insert_dylib to add LCs)
        let currentSize = data.count
        if currentSize < textSegSize - textSectionSize {
            data.append(Data(count: textSegSize - textSectionSize - currentSize))
        }

        // __text section content: single arm64 `ret` instruction
        data.append(contentsOf: [0xC0, 0x03, 0x5F, 0xD6] as [UInt8])

        // Verify we're at the right offset
        assert(data.count == textSegSize, "Text segment size mismatch: \(data.count) != \(textSegSize)")

        // === __LINKEDIT content ===

        // nlist_64 entry (local symbol pointing at our ret instruction)
        appendLE(&data, UInt32(1))                        // n_strx: offset into strtab
        appendLE(&data, UInt8(0x0E))                      // n_type: N_SECT
        appendLE(&data, UInt8(1))                         // n_sect: section 1 (__text)
        appendLE(&data, UInt16(0))                        // n_desc
        appendLE(&data, UInt64(textSectionOffset))        // n_value: address of the ret

        // strtab
        data.append(contentsOf: strtabData)

        // Pad __LINKEDIT to stated size
        let linkeditPadding = linkeditSize - nlistSize - strtabData.count
        if linkeditPadding > 0 {
            data.append(Data(count: linkeditPadding))
        }

        assert(data.count == totalFileSize, "Total file size mismatch: \(data.count) != \(totalFileSize)")

        return data
    }

    // MARK: - Helper: byte appenders

    private static func appendLE(_ data: inout Data, _ value: UInt8) {
        data.append(value)
    }

    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendLE(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    private static func appendBigEndian(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        data.append(Data(bytes: &v, count: 4))
    }

    /// Append a 16-byte segment name (zero-padded)
    private static func appendSegName(_ data: inout Data, _ name: String) {
        var bytes = Array(name.utf8)
        while bytes.count < 16 { bytes.append(0) }
        data.append(contentsOf: bytes.prefix(16))
    }

    /// Append a 16-byte section name (zero-padded)
    private static func appendSectName(_ data: inout Data, _ name: String) {
        appendSegName(&data, name)  // same format
    }

    private static func alignTo(_ value: Int, _ alignment: Int) -> Int {
        let mask = alignment - 1
        return (value + mask) & ~mask
    }
}
