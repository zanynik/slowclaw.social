import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "SlowClaw — A little more room for your thoughts",
  description: "A quiet place to journal, connect your thoughts, and follow your curiosity. Pair privately with SlowClaw on your iPhone.",
  robots: { index: true, follow: true },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
