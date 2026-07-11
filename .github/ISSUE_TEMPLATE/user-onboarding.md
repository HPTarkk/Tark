---
name: User Onboarding Journey
about: Design and implement first-time user experience
title: "Feature: Improved User Onboarding Journey for First-Time Users"
labels: ["enhancement", "UX"]
assignees: ["P-B1101"]
---

## 🎯 Objective
Create a smooth, intuitive first-time user experience that guides new users through Tark setup and helps them choose the right connection mode.

## 📋 Requirements

### 1. Landing Page Enhancement
- [ ] Review current landing page flow (`lib/feature/landing/`)
- [ ] Simplify identity setup (name input, profile image)
- [ ] Add clear CTAs (call-to-action) for different transport modes
- [ ] Ensure RTL support for Persian users

### 2. Transport Mode Selection
- [ ] Improve "Combined WiFi / Hotspot page" UX
- [ ] Add visual guide explaining:
  - Wi-Fi: "Same network already?"
  - Bluetooth: "Two Androids, offline?"
  - Hotspot Bridge: "iPhone + Android, no network?"
  - Guest: "Talk to someone without the app?"
- [ ] Add inline tooltips/help icons

### 3. Onboarding Tips & Guidance
- [ ] Implement/enhance the animated tips sheet shown on first launch
- [ ] Topics to cover:
  - Recommended: ANC/handsfree headset
  - Best practices: proper helmet wearing
  - Voice settings: VOX (voice-activated) defaults
  - Permissions: why each permission is needed
- [ ] Make it skippable but informative
- [ ] One-time per app version (per current design)

### 4. Permissions Flow
- [ ] Review existing Permissions page (`lib/feature/settings/`)
- [ ] Make permission requests contextual (request when needed)
- [ ] Show clear explanations:
  - Microphone: "To transmit your voice"
  - Bluetooth: "For wireless connection"
  - Location: "For Bluetooth discovery (Android ≤32)"
  - Hotspot: "To create/join local networks"

### 5. Cold-Start Routing
- [ ] Ensure first-time users see Landing, not quick-access jump to channel
- [ ] Implement proper `QuickAccess.resolveStartLocation()` logic
- [ ] Add settings toggle for skipping splash/tips

### 6. UI/UX Polish
- [ ] Use circular-reveal transition (already supported)
- [ ] Apply warm dark "night radio" theme
- [ ] Ensure smooth animations
- [ ] Test on both Android & iOS
- [ ] Test with both Persian (فارسی) and English

## 📁 Relevant Files
- `lib/feature/landing/` — Lobby/landing page
- `lib/feature/splash/` — Branded splash screen
- `lib/feature/transfer/` — WiFi/Hotspot/Bluetooth transport selection
- `lib/feature/settings/` — Settings and Permissions pages
- `lib/core/router/` — GoRouter configuration
- `lib/app/quick_access.dart` — Cold-start routing logic
- `lib/core/theme/` — Theme & circular-reveal transition

## 🔗 Related
- Current features in README.md:
  - Usage tips: [Features#usage-tips](https://github.com/HPTark/Tark#features)
  - Bilingual support: [Features#bilingual](https://github.com/HPTark/Tark#features)
  - Quick access: [Features#quick-access](https://github.com/HPTark/Tark#features)
  - Permissions: [Android permissions](https://github.com/HPTark/Tark#android-permissions)

## ✅ Definition of Done
- [ ] New users guided through all setup steps
- [ ] Transport mode selection is intuitive
- [ ] Permissions explanations are clear
- [ ] Tips/guidance helpful without being intrusive
- [ ] Works on Android & iOS
- [ ] Bilingual (Persian/English) with proper RTL handling
- [ ] No accessibility issues (screen readers, etc.)
- [ ] Performance: cold-start ≤3.5s
- [ ] PR reviewed and merged

## 💡 Design Notes
- Keep it quick — first-time setup should be <2 minutes
- Use illustrations/icons when possible
- Test with actual new users if possible
- Consider different skill levels (tech-savvy vs. not)
