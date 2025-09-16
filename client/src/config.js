export const API_URL =
    (typeof window !== "undefined" &&
        window._env_ &&
        window._env_.VITE_API_URL) ||
    import.meta.env.VITE_API_URL;