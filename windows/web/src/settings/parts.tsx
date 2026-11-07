import type { ReactNode } from "react";

export const Header = ({ children, action }: { children: ReactNode; action?: ReactNode }) => <div className="set-header">{children}{action}</div>;
export const Card = ({ children }: { children: ReactNode }) => <div className="set-card">{children}</div>;
export const Note = ({ children }: { children: ReactNode }) => <div className="set-note">{children}</div>;
export function Row({ title, detail, children, stack }: { title: ReactNode; detail?: ReactNode; children?: ReactNode; stack?: boolean }) {
  return (
    <div className={`set-row${stack ? " stack" : ""}`}>
      <div className="main"><div>{title}</div>{detail && <div className="detail">{detail}</div>}</div>
      {children && <div className="ctl">{children}</div>}
    </div>
  );
}
