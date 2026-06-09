# Design System Strategy: The Kinetic Midnight

## 1. Overview & Creative North Star

**Creative North Star: "The Obsidian Performance Lab"**

This design system is built to transform the mundane act of calorie tracking into a high-performance, editorial experience. We are moving away from the "utility app" aesthetic and toward a "luxury biometric" interface. The system leverages the deep obsidian depths of charcoal backgrounds to make vibrant progress indicators feel like glowing neon instrumentation.

To break the "template" look, we utilize **Intentional Asymmetry**. We don't just center elements; we use large-scale display typography juxtaposed with compact, high-density data. We favor overlapping elements—such as progress rings that subtly break the boundaries of their parent cards—to create a sense of kinetic energy and technical sophistication.

---

## 2. Colors & Surface Philosophy

The palette is rooted in a pure dark mode experience, utilizing a sophisticated hierarchy of charcoal tones rather than flat blacks.

### Color Palette (Material Design Tokens)
* **Background:** `#0e0e0e` (The Canvas)
* **Primary (Nutrition/Success):** `#6bff8f`
* **Secondary (Energy/Flow):** `#c180ff`
* **Tertiary (Warning/Burn):** `#ff8439`
* **Surface Tiers:** From `surface-container-lowest` (`#000000`) to `surface-bright` (`#2c2c2c`).

### The "No-Line" Rule
**Lines are a failure of hierarchy.** Within this design system, 1px solid borders for sectioning are strictly prohibited. Boundaries must be defined solely through background color shifts. For instance, a meal card (`surface-container-high`) should sit on a section background (`surface-container-low`) without a stroke.

### Surface Hierarchy & Nesting
Treat the UI as a series of physical layers.
* **The Base:** `background` (#0e0e0e).
* **The Content Area:** `surface-container-low` (#131313).
* **The Interactive Cards:** `surface-container-highest` (#262626).
Nesting an element inside a card? Use `surface-bright` (#2c2c2c) to create a "pitted" or "recessed" look for inputs or secondary data points.

### The "Glass & Gradient" Rule
To elevate the experience, use **Glassmorphism** for floating UI like the Bottom Navigation or the FAB background.
* **Signature Texture:** Use a 45-degree linear gradient from `primary` (#6bff8f) to `primary_container` (#0abc56) for major progress rings and active states to give them a three-dimensional, liquid glow.

---

## 3. Typography

The system uses a dual-font strategy to balance editorial elegance with technical readability.

* **Display & Headline (Manrope):** Chosen for its modern, wide stance. Use `display-lg` (3.5rem) for the daily calorie total to make the data feel like an art piece.
* **Title & Body (Inter):** Chosen for its exceptional legibility at small scales. Inter is used for all functional data, ingredient lists, and settings.

**Typography as Identity:** We use extreme scale contrast. A `display-lg` number should sit directly next to a `label-sm` unit (e.g., "1600" in Manrope next to "KCAL" in Inter) to create an authoritative, high-fashion biometric look.

---

## 4. Elevation & Depth

We eschew traditional drop shadows in favor of **Tonal Layering**.

* **The Layering Principle:** Depth is achieved by "stacking" surface tokens. A `surface-container-lowest` card placed on a `surface-container-high` background creates a "cut-out" effect, while the inverse creates a "lifted" effect.
* **Ambient Shadows:** For the Floating Action Button (FAB) or high-level modals, use a custom shadow: `0px 20px 40px rgba(0, 0, 0, 0.4)`. The shadow must be large, soft, and tinted by the background color to feel integrated.
* **The "Ghost Border" Fallback:** If accessibility requires a container edge, use a "Ghost Border": `outline-variant` (#484847) at 15% opacity. It should be felt, not seen.
* **Backdrop Blur:** Floating elements (like the Add Meal header) must use a `blur(20px)` effect on a semi-transparent `surface` color to allow the vibrant progress colors to bleed through as the user scrolls.

---

## 5. Components

### The "Subtle FAB"
Unlike standard Material FABs, this system's FAB is a minimalist circle using `surface-container-highest` with a `primary` (#6bff8f) icon. It should feel like a specialized tool, not a generic button.

### Progress Rings & Bars
* **Minimalist Rings:** Use a stroke width of 12-16px. The track should be `surface-variant` with the progress indicator using a vibrant gradient (e.g., `tertiary` to `tertiary_container`).
* **Progress Bars:** Always use `rounded-full` (9999px) for caps.

### Cards & Lists
* **Strict Rule:** No dividers. Use `spacing-6` (1.5rem) to separate list items or subtle background shifts between cards.
* **Rounding:** Apply `rounded-xl` (1.5rem) for main meal cards to create a friendly, organic feel against the high-contrast dark palette.

### Input Fields
* **Visual Style:** Use a "Filled" style with `surface-container-highest` and a `rounded-md` corner.
* **State:** On focus, do not change the border; change the background to `surface-bright` and transition the icon color to `primary`.

---

## 6. Do's and Don'ts

### Do:
* **Do** use `primary_fixed` and `secondary_fixed` for high-emphasis data points that must remain vibrant regardless of the background luminance.
* **Do** embrace negative space. If a screen feels "crowded," increase the spacing between cards rather than adding a line.
* **Do** use `on_surface_variant` (#adaaaa) for secondary labels (like "Eaten" or "Burned") to keep the focus on the primary white data.

### Don't:
* **Don't** use pure white (#FFFFFF) for large blocks of text; use `on_surface` for headers and `on_surface_variant` for body text to reduce eye strain.
* **Don't** use 100% opaque borders. They break the "performance lab" immersion.
* **Don't** use standard "Material Blue." Use the signature `secondary` purple or `tertiary` orange for a custom, premium feel.
* **Don't** use sharp corners. Calorie tracking is a personal, holistic journey; the UI should feel soft and approachable through consistent use of the `roundedness scale`.