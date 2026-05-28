/**
 * StatusPill.tsx — Consistent status badge component.
 *
 * Replaces inline styled status indicators throughout the app
 * with a consistent, accessible, themed component.
 */

type StatusPillProps = {
  children: React.ReactNode;
  variant?: "default" | "success" | "error" | "warning" | "accent";
  size?: "sm" | "md";
  className?: string;
  title?: string;
};

export function StatusPill({
  children,
  variant = "default",
  size = "sm",
  className = "",
  title,
}: StatusPillProps) {
  return (
    <span
      className={`status-pill status-pill-${variant} status-pill-${size} ${className}`}
      title={title}
    >
      {children}
    </span>
  );
}
