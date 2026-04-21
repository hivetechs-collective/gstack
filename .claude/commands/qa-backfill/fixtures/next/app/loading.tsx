// Intentionally present — the Stage 00 crawler MUST skip this file
// per 00-crawl.md §0.3 (Next.js loading.tsx is a loading UI, not a page).
export default function Loading() {
  return <p>loading...</p>;
}
