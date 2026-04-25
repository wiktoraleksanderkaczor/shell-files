---
inclusion: manual
---

# WORKFLOW UPDATE GUIDE

How to update `WORKFLOW.md` following its structural principles.

## File Structure Philosophy

This workflow is a **directed graph** designed for:
1. **Linear Flow**: Read top-to-bottom, each step builds on previous
2. **Cognitive Order**: Foundational principles first, execution details follow
3. **Precedence by Position**: Earlier instructions override later ones
4. **Inline Content**: All information present at each step (no "see section X")
5. **Minimized Loops**: Decision points route forward, no circular references
6. **Appendices for Reference**: Detailed patterns in appendices

## Content Design Principle

- **Main steps**: Complete actionable rules (1-2 sentences each) - no hopping needed to act
- **Appendices**: Extended examples, code samples, rationale - for deeper understanding
- **Cross-references**: Only for "see examples" or "for more detail", never for essential rules
- **Deduplication**: When content appears in multiple steps, keep full version at first/primary location, brief summary with reference at others

## How to Update

**Adding New Content**:
1. Determine if **general principle** (main steps) or **specific pattern** (appendix)
2. Place in **cognitive order** - what must be known first?
3. If affects multiple steps, inline at **earliest relevant step**

**Modifying Existing Content**:
1. Ensure inline content is complete
2. Check downstream step impacts
3. Verify precedence rules hold

**Restructuring**:
1. Maintain directed graph flow (no circular dependencies)
2. Keep decision points clear: `→ Go to STEP X`
3. Preserve cognitive order
4. Test: can you follow linearly without jumping back?

## Content Placement Rules

- **Core interaction** → STEP 1-4 (user interaction)
- **Context/setup** → STEP 5-8 (preparation)
- **Discovery/reading** → STEP 9-10 (information gathering)
- **Planning/execution** → STEP 11-12 (thinking and doing)
- **Verification/cleanup** → STEP 13-14 (quality assurance)
- **Documentation/reporting** → STEP 15-16 (completion)
- **Detailed patterns** → Appendices (reference)
