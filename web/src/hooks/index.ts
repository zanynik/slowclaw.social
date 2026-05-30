/**
 * hooks/index.ts — Central export for all custom hooks.
 *
 * Keeps import paths clean and discoverable.
 */

export { useMediaQuery, useIsLargeScreen, useIsMobile, useIsTablet, usePrefersReducedMotion, usePrefersDarkMode } from "./useMediaQuery";
export { useDebounce, useDebouncedCallback, useAutosave } from "./useDebounce";
export { useKeyboardHeight, useIsKeyboardOpen } from "./useKeyboardHeight";
export { useScrollDirection } from "./useScrollDirection";
