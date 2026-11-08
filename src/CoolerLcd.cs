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
    public class Animator
    {
        public int Size = 720;
        public int Rotate = 0;
        public PointF ClaudeAt = new PointF(82, 144);
        public PointF CodexAt = new PointF(82, 454);
        public float ClaudeR = 24, CodexR = 22;
        public Color CardColor = ColorTranslator.FromHtml("#151B26");
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
                DrawClaude(g, ClaudeAt.X, ClaudeAt.Y, ClaudeR, t);
                DrawCodex(g, CodexAt.X, CodexAt.Y, CodexR, t);
            }
            return Codec.Raw(frame);
        }

        // Claude spark: slow spin + gentle "breathing" of the rays
        public static void DrawClaude(Graphics g, float cx, float cy, float r, double t)
        {
            double phase = t * 0.9;
            double breathe = 0.88 + 0.12 * Math.Sin(t * 2.4);
            using (var b = new SolidBrush(ColorTranslator.FromHtml("#D97757")))
            {
                const int rays = 12;
                for (int i = 0; i < rays; i++)
                {
                    double a = i * 2 * Math.PI / rays + phase;
                    double len = (i % 2 == 1 ? r * 0.78 : r) * breathe;
                    double wid = r * 0.16;
                    double px = Math.Cos(a), py = Math.Sin(a), nx = -py, ny = px;
                    g.FillPolygon(b, new[] {
                        new PointF((float)(cx + nx * wid / 2), (float)(cy + ny * wid / 2)),
                        new PointF((float)(cx + px * len), (float)(cy + py * len)),
                        new PointF((float)(cx - nx * wid / 2), (float)(cy - ny * wid / 2)) });
                }
                g.FillEllipse(b, cx - r * 0.14f, cy - r * 0.14f, r * 0.28f, r * 0.28f);
            }
        }

        // Codex knot: six rounded loops, slowly rotating
        public static void DrawCodex(Graphics g, float cx, float cy, float r, double t)
        {
            using (var pen = new Pen(ColorTranslator.FromHtml("#F2F4F8"), r * 0.17f))
            {
                pen.LineJoin = LineJoin.Round;
                var st = g.Save();
                g.TranslateTransform(cx, cy);
                g.RotateTransform((float)(t * 40 % 360));
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
    }
}
