// Intentionally present — the Stage 00 crawler MUST skip this file
// per 00-crawl.md §0.3 (Next.js layout.tsx is a wrapper, not a page).
export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
