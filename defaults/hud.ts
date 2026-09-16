// One nonactivating panel drawn with `hs.canvas`, shared by the leader menu
// and the window list: a title, rows of key, label, and hint, and a footer
// whose height never changes so feedback cannot move the list. The canvas
// ignores mouse events and never takes focus. HS2 canvas positions use
// AppKit's y-up coordinates; screen frames use y-down coordinates. A canvas
// belongs to one display/Space, so a new placement key recreates it.
import type {HS} from "../api/hs.ts";
import type {Frame} from "../api/spaces.ts";

export interface PanelRow {
  /** The key or number shown first; empty for a plain row. */
  key: string;
  label: string;
  /** A second, smaller line under the label. */
  detail?: string;
  /** Right-aligned text such as a shortcut or a submenu mark. */
  hint?: string;
  dim?: boolean;
  highlight?: boolean;
}

export interface PanelContent {
  title: string;
  rows: PanelRow[];
  footer: string;
  /** Rows fill each column top to bottom before the next column starts. */
  columns: number;
  columnWidth: number;
}

export interface Placement {
  screen: Frame;
  anchor: "bottomRight" | "bottomCenter";
  /** Changing keys recreate the native window, for example on another Desktop. */
  key: string;
}

const titleHeight = 36,
  footerHeight = 34,
  margin = 20;
const white = (alpha: number) => ({red: 1, green: 1, blue: 1, alpha});

export function frameFor(
  screen: Frame,
  primary: {h: number},
  width: number,
  height: number,
  anchor: Placement["anchor"] = "bottomRight",
): Frame {
  return {
    x:
      anchor === "bottomCenter"
        ? screen.x + Math.round((screen.w - width) / 2)
        : screen.x + screen.w - width - margin,
    y: primary.h - screen.y - screen.h + margin,
    w: width,
    h: height,
  };
}

export class Panel {
  private readonly hs: HS;
  private canvas: HSCanvas | null = null;
  private signature: string | null = null;
  private placementKey: string | null = null;

  constructor(hs: HS) {
    this.hs = hs;
  }

  show(content: PanelContent, placement: Placement): void {
    const primary = this.hs.screen.primary();
    if (!primary) {
      this.hide();
      return;
    }
    if (placement.key !== this.placementKey) {
      if (this.canvas) this.canvas.destroy();
      this.canvas = null;
      this.signature = null;
      this.placementKey = placement.key;
    }
    const rowHeight = content.rows.some((row) => row.detail) ? 42 : 30,
      perColumn = Math.max(1, Math.ceil(content.rows.length / content.columns)),
      columns = Math.max(1, Math.min(content.columns, content.rows.length));
    const width = Math.min(content.columnWidth * columns, placement.screen.w - 2 * margin),
      column = width / columns,
      height = titleHeight + perColumn * rowHeight + footerHeight;
    const frame = frameFor(placement.screen, primary.fullFrame, width, height, placement.anchor);
    const signature = JSON.stringify([frame, content]);
    if (signature === this.signature) return;
    const text = (
      value: string,
      x: number,
      y: number,
      w: number,
      size: number,
      alpha = 1,
      extra: Record<string, unknown> = {},
    ) => ({
      type: "text",
      text: value.replace(/\s+/g, " "),
      frame: {x, y, w, h: size + 8},
      textSize: size,
      textColor: white(alpha),
      textLineBreak: "truncateTail",
      ...extra,
    });
    const elements: object[] = [
      {
        type: "rectangle",
        action: "fill",
        frame: {x: 0, y: 0, w: width, h: height},
        roundedRectRadii: {xRadius: 14, yRadius: 14},
        fillColor: {red: 0.08, green: 0.09, blue: 0.12, alpha: 0.96},
      },
      text(content.title.toUpperCase(), 18, 12, width - 36, 11, 0.6, {textWeight: "semibold"}),
    ];
    content.rows.forEach((row, index) => {
      const x = Math.floor(index / perColumn) * column,
        y = titleHeight + (index % perColumn) * rowHeight,
        alpha = row.dim ? 0.45 : 1;
      if (row.highlight)
        elements.push({
          type: "rectangle",
          action: "fill",
          frame: {x: x + 8, y: y - 2, w: column - 16, h: rowHeight - 4},
          roundedRectRadii: {xRadius: 7, yRadius: 7},
          fillColor: {red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5},
        });
      const hintWidth = row.hint ? Math.min(120, column / 3) : 0;
      elements.push(text(row.key, x + 18, y + 5, 44, 14, alpha, {textWeight: "semibold"}));
      elements.push(
        text(row.label, x + 62, y + (row.detail ? 0 : 5), column - 76 - hintWidth, 14, alpha),
      );
      if (row.detail) elements.push(text(row.detail, x + 62, y + 18, column - 76, 10, 0.6));
      if (row.hint)
        elements.push(
          text(row.hint, x + column - 18 - hintWidth, y + 6, hintWidth, 12, 0.55, {
            textAlignment: "right",
          }),
        );
    });
    elements.push(text(content.footer, 18, height - 26, width - 36, 11, 0.5));
    if (!this.canvas)
      this.canvas = this.hs.canvas
        .create(frame)
        .level("floating")
        .behaviorList(["canJoinAllSpaces", "stationary", "ignoresCycle"])
        .clickActivating(false)
        .ignoreMouseEvents(true);
    this.canvas.setFrame(frame).replaceElements(elements).show();
    this.signature = signature;
  }

  hide(): void {
    if (this.canvas) this.canvas.hide();
    this.signature = null;
  }

  destroy(): void {
    if (this.canvas) this.canvas.destroy();
    this.canvas = null;
    this.signature = this.placementKey = null;
  }
}
