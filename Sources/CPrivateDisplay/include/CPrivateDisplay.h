// Types for undocumented macOS display APIs. Layouts follow public prior art
// (displayplacer, MonitorControl). They may change between macOS releases.
//
// No private function is declared here: DisplayCore resolves every private symbol at
// runtime with dlsym (PrivateSymbols.swift), so a symbol Apple removes turns a feature
// off instead of preventing launch.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

CF_ASSUME_NONNULL_BEGIN

// Mode record filled by CGSGetDisplayModeDescriptionOfLength. Only the named fields
// are relied upon; the rest is padding of unknown meaning.
typedef struct __attribute__((packed)) {
    uint32_t modeNumber;   // 0x00
    uint32_t flags;        // 0x04
    uint32_t width;        // 0x08 logical points
    uint32_t height;       // 0x0C logical points
    uint32_t depth;        // 0x10
    uint8_t  _pad0[170];   // 0x14
    uint16_t freq;         // 0xBE refresh rate in Hz (0 when unknown)
    uint8_t  _pad1[16];    // 0xC0
    float    density;      // 0xD0 backing scale (2.0 for HiDPI)
} CGSDisplayModeDescription;

_Static_assert(sizeof(CGSDisplayModeDescription) == 0xD4, "CGS mode layout");

// IOAVService handle (Apple silicon DDC/CI), returned retained by IOAVServiceCreateWithService.
typedef CFTypeRef IOAVServiceRef;

CF_ASSUME_NONNULL_END
