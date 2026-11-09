// sama-lcd-ai-usage - helpers for the SAMA (Turing/TURZX-based) 720x720 cooler LCD.
// MIT License. See PROTOCOL.md for the wire format.
// Delta format (command 204), worked out by observing the vendor app's output:
//   single changed pixel : [0x80 | pos>>16][pos>>8][pos] + BGRA
//   run of n>=2 pixels   : [pos>>16][pos>>8][pos][n>>8][n] + n*BGRA
//   a pixel is "changed" if any of its 4 bytes differ; max run length 65000.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace CoolerLcd
{
    public static class Codec
    {
        public const int MaxRun = 65000;

        // Returns encoded bytes (length in 'len'), or null if a run exceeds MaxRun (send a full frame instead).
        public static byte[] Delta(byte[] prev, byte[] cur, out int len)
        {
            int px = cur.Length / 4;
            var ms = new MemoryStream(65536);
            int i = 0;
            while (i < px)
            {
                if (!Diff(prev, cur, i)) { i++; continue; }
                int j = i + 1;
                while (j < px && Diff(prev, cur, j)) j++;
                int n = j - i;
                if (n > MaxRun) { len = 0; return null; }
                if (n == 1)
                {
                    ms.WriteByte((byte)(0x80 | ((i >> 16) & 0x7F)));
                    ms.WriteByte((byte)(i >> 8)); ms.WriteByte((byte)i);
                }
                else
                {
                    ms.WriteByte((byte)(i >> 16)); ms.WriteByte((byte)(i >> 8)); ms.WriteByte((byte)i);
                    ms.WriteByte((byte)(n >> 8)); ms.WriteByte((byte)n);
                }
                ms.Write(cur, i * 4, n * 4);
                i = j;
            }
            len = (int)ms.Length;
            return ms.ToArray();
        }

        static bool Diff(byte[] a, byte[] b, int p)
        {
            int k = p * 4;
            return a[k] != b[k] || a[k + 1] != b[k + 1] || a[k + 2] != b[k + 2] || a[k + 3] != b[k + 3];
        }

        public static byte[] Raw(Bitmap bmp)
        {
            var r = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var bd = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var raw = new byte[bmp.Width * bmp.Height * 4];
            Marshal.Copy(bd.Scan0, raw, 0, raw.Length);
            bmp.UnlockBits(bd);
            return raw;
        }
    }

    // Logos are simplified original drawings in the spirit of each product's mark (not the official artwork).
    // Draws the animated logos on top of a pre-rendered (already rotated) base frame.
    // Mood: 0 = calm (< 60 %), 1 = worried (60-85 %), 2 = stressed (>= 85 %), from the higher of the two windows.
    public class Animator
    {
        public int Size = 720;
        public int Rotate = 0;
        // v2 layout: logos centred in the 236 px left column of each card
        public PointF ClaudeAt = new PointF(142, 196);
        public PointF CodexAt = new PointF(142, 512);
        public float ClaudeR = 176, CodexR = 80;      // critter height / knot radius in pixels
        public int ClaudeMood = 0, CodexMood = 0;
        Bitmap frame;
        public Bitmap LastFrame { get { return frame; } }

        public byte[] Compose(Bitmap baseFrame, double t)
        {
            if (frame == null) frame = new Bitmap(Size, Size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(frame))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.DrawImageUnscaled(baseFrame, 0, 0);
                g.CompositingMode = CompositingMode.SourceOver;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TranslateTransform(Size / 2f, Size / 2f);
                g.RotateTransform(Rotate);
                g.TranslateTransform(-Size / 2f, -Size / 2f);
                DrawClaude(g, ClaudeAt.X, ClaudeAt.Y, ClaudeR, t, ClaudeMood);
                DrawCodex(g, CodexAt.X, CodexAt.Y, CodexR, t, CodexMood);
            }
            return Codec.Raw(frame);
        }

        // ---- Claude: original pixel-art orange critter (walks in place, bobs, blinks; sweats when busy)
        static readonly string[] CritterBody = {
            "...BBBBBBBB...",
            "..BBBBBBBBBB..",
            "..BB..BB..BB..",
            "..BB..BB..BB..",
            "AABBBBBBBBBBAA",
            "AABBBBBBBBBBAA",
            "..BBBBBBBBBB..",
            "..BBBBBBBBBB..",
        };
        static readonly Color Orange = ColorTranslator.FromHtml("#D97757");
        static readonly Color Dark = ColorTranslator.FromHtml("#1B1B1F");
        static readonly Color Sweat = ColorTranslator.FromHtml("#7CC7FF");

        // size = total sprite height in pixels
        public static void DrawClaude(Graphics g, float cx, float cy, float size, double t, int mood)
        {
            const int cols = 14, rows = 11;
            float px = size / rows;
            double rate = mood == 2 ? 3.5 : mood == 1 ? 2.5 : 2;   // steps per second (kept slow on purpose)
            int step = (int)(t * rate) % 2;
            float bob = step == 1 ? -px : 0;
            float shake = mood == 2 ? (float)Math.Sin(t * 5) * px * 0.3f : 0;      // gentle sway
            bool blink = mood == 0 && (t % 3.2) > 3.0;
            float x0 = cx - cols * px / 2 + shake, y0 = cy - rows * px / 2;
            var oldMode = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.None;
            using (var ob = new SolidBrush(Orange))
            using (var db = new SolidBrush(Dark))
            using (var sb = new SolidBrush(Sweat))
            {
                for (int r = 0; r < CritterBody.Length; r++)
                    for (int c = 0; c < cols; c++)
                    {
                        char ch = CritterBody[r][c];
                        if (ch == '.') continue;
                        float y = y0 + r * px + bob;
                        if (ch == 'A') y += (step == 0 ? 0 : px * 0.5f) * (c < 7 ? 1 : -1) * (mood == 2 ? 2 : 1);
                        g.FillRectangle(ob, x0 + c * px, y, px + 0.5f, px + 0.5f);
                    }
                foreach (int ec in new[] { 4, 8 })            // eyes: 2x2 cells
                {
                    float ex = x0 + ec * px, ey = y0 + 2 * px + bob;
                    if (mood != 0 || blink) g.FillRectangle(ob, ex, ey, px * 2 + 0.5f, px * 2 + 0.5f);
                    if (mood == 2)
                    {
                        bool left = ec == 4;
                        using (var pen = new Pen(Dark, px * 0.55f))
                        {
                            pen.StartCap = LineCap.Square; pen.EndCap = LineCap.Square;
                            float a = ex + px * 0.3f, b = ex + px * 1.7f, top = ey + px * 0.25f, mid = ey + px, bot = ey + px * 1.75f;
                            g.SmoothingMode = SmoothingMode.AntiAlias;
                            if (left) g.DrawLines(pen, new[] { new PointF(a, top), new PointF(b, mid), new PointF(a, bot) });
                            else g.DrawLines(pen, new[] { new PointF(b, top), new PointF(a, mid), new PointF(b, bot) });
                            g.SmoothingMode = SmoothingMode.None;
                        }
                    }
                    else if (blink) g.FillRectangle(db, ex, ey + px * 1.6f, px * 2, px * 0.4f);
                    else if (mood == 1) g.FillRectangle(db, ex + px, ey, px + 0.5f, px * 2 + 0.5f);   // glancing sideways
                    else g.FillRectangle(db, ex, ey, px * 2 + 0.5f, px * 2 + 0.5f);
                }
                if (mood >= 1) Drop(g, sb, x0 + 12.4f * px, y0 + 0.2f * px + bob, px, t, 0);
                if (mood == 2) Drop(g, sb, x0 + 0.9f * px, y0 + 0.6f * px + bob, px, t, 0.5);
                int[] legCols = { 3, 5, 8, 10 };
                for (int i = 0; i < legCols.Length; i++)
                {
                    bool lifted = (i % 2) == step;
                    g.FillRectangle(ob, x0 + legCols[i] * px, y0 + 8 * px + (lifted ? bob : 0), px + 0.5f, (lifted ? 2 : 3) * px + 0.5f);
                }
            }
            g.SmoothingMode = oldMode;
        }

        static void Drop(Graphics g, Brush b, float x, float y, float px, double t, double phase)
        {
            double k = (t * 0.45 + phase) % 1.0;                 // drop slides down and restarts
            float dy = (float)(k * px * 3);
            g.FillRectangle(b, x, y + dy, px * 0.5f, px * 0.5f);
            g.FillRectangle(b, x - px * 0.25f, y + dy + px * 0.5f, px, px * 0.8f);
        }

        // ---- Codex knot: six rounded loops; speed and colour follow the mood
        public static void DrawCodex(Graphics g, float cx, float cy, float r, double t, int mood)
        {
            Color col = mood == 2 ? ColorTranslator.FromHtml("#FF6B6B") : mood == 1 ? ColorTranslator.FromHtml("#FFD84D") : ColorTranslator.FromHtml("#F2F4F8");
            if (mood == 2)
            {
                double p = 0.75 + 0.25 * Math.Sin(t * 2.5);     // slow pulse
                col = Color.FromArgb(255, (int)(col.R * p + 255 * (1 - p)), (int)(col.G * p + 120 * (1 - p)), (int)(col.B * p + 120 * (1 - p)));
            }
            double speed = mood == 2 ? 60 : mood == 1 ? 30 : 15;    // degrees per second
            using (var pen = new Pen(col, r * 0.17f))
            {
                pen.LineJoin = LineJoin.Round;
                var st = g.Save();
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TranslateTransform(cx, cy);
                g.RotateTransform((float)(t * speed % 360));
                for (int i = 0; i < 6; i++)
                {
                    g.RotateTransform(60);
                    using (var p = new GraphicsPath())
                    {
                        float w = r * 0.62f, h = r * 1.05f, rr = r * 0.3f;
                        float x0 = -w / 2 + r * 0.18f, y0 = -h + r * 0.12f;
                        p.AddArc(x0, y0, 2 * rr, 2 * rr, 180, 90);
                        p.AddArc(x0 + w - 2 * rr, y0, 2 * rr, 2 * rr, 270, 90);
                        p.AddLine(x0 + w, y0 + rr, x0 + w, y0 + h * 0.62f);
                        g.DrawPath(pen, p);
                    }
                }
                g.Restore(st);
            }
        }

        // ---- soft brand-colour glow behind a logo, clipped to its card (used for the static base frame)
        public static void Glow(Graphics g, GraphicsPath clip, float cx, float cy, float radius, Color c, int alpha)
        {
            var st = g.Save();
            g.SetClip(clip);
            using (var p = new GraphicsPath())
            {
                p.AddEllipse(cx - radius, cy - radius, radius * 2, radius * 2);
                using (var br = new PathGradientBrush(p))
                {
                    br.CenterColor = Color.FromArgb(alpha, c);
                    br.SurroundColors = new[] { Color.FromArgb(0, c) };
                    g.FillPath(br, p);
                }
            }
            g.Restore(st);
        }
    }
}
