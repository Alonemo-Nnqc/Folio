using System.Runtime.InteropServices;

namespace Folio.Core.Translate.Typeset;

/// <summary>Subsets of TrueType fonts embedded in the translation layer (Skia embeds whole fonts: a Chinese font is
/// 20 MB). Glyph ids are kept, so the PDF's glyph codes stay valid. Uses hb-subset of HarfBuzzSharp's native library.</summary>
public static class FontSubsetter
{
    const string Library = "libHarfBuzzSharp";
    const uint RetainGids = 0x2, NoHinting = 0x1;

    [DllImport(Library)] static extern IntPtr hb_blob_create(IntPtr data, uint length, int mode, IntPtr userData, IntPtr destroy);
    [DllImport(Library)] static extern void hb_blob_destroy(IntPtr blob);
    [DllImport(Library)] static extern IntPtr hb_blob_get_data(IntPtr blob, out uint length);
    [DllImport(Library)] static extern IntPtr hb_face_create(IntPtr blob, uint index);
    [DllImport(Library)] static extern void hb_face_destroy(IntPtr face);
    [DllImport(Library)] static extern IntPtr hb_face_reference_blob(IntPtr face);
    [DllImport(Library)] static extern IntPtr hb_subset_input_create_or_fail();
    [DllImport(Library)] static extern void hb_subset_input_destroy(IntPtr input);
    [DllImport(Library)] static extern IntPtr hb_subset_input_glyph_set(IntPtr input);
    [DllImport(Library)] static extern IntPtr hb_subset_input_unicode_set(IntPtr input);
    [DllImport(Library)] static extern void hb_subset_input_set_flags(IntPtr input, uint flags);
    [DllImport(Library)] static extern IntPtr hb_subset_or_fail(IntPtr face, IntPtr input);
    [DllImport(Library)] static extern void hb_set_add(IntPtr set, uint codepoint);
    [DllImport(Library)] static extern void hb_set_clear(IntPtr set);

    /// <summary>The font program with only <paramref name="glyphs"/> (and .notdef) left, or null when it can't be done.</summary>
    public static byte[]? Subset(byte[] font, IEnumerable<ushort> glyphs)
    {
        if (font.Length < 12) return null;
        var handle = GCHandle.Alloc(font, GCHandleType.Pinned);
        IntPtr blob = IntPtr.Zero, face = IntPtr.Zero, input = IntPtr.Zero, subset = IntPtr.Zero, result = IntPtr.Zero;
        try
        {
            // HB_MEMORY_MODE_READONLY: HarfBuzz reads the pinned array, which outlives every object made here.
            blob = hb_blob_create(handle.AddrOfPinnedObject(), (uint)font.Length, 1, IntPtr.Zero, IntPtr.Zero);
            face = hb_face_create(blob, 0);
            input = hb_subset_input_create_or_fail();
            if (input == IntPtr.Zero) return null;
            var set = hb_subset_input_glyph_set(input);
            hb_set_add(set, 0);
            foreach (var g in glyphs) hb_set_add(set, g);
            hb_set_clear(hb_subset_input_unicode_set(input));
            hb_subset_input_set_flags(input, RetainGids | NoHinting);
            subset = hb_subset_or_fail(face, input);
            if (subset == IntPtr.Zero) return null;
            result = hb_face_reference_blob(subset);
            var data = hb_blob_get_data(result, out uint length);
            if (data == IntPtr.Zero || length < 12 || length >= font.Length) return null;
            var bytes = new byte[length];
            Marshal.Copy(data, bytes, 0, (int)length);
            return bytes;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            return null;
        }
        finally
        {
            if (result != IntPtr.Zero) hb_blob_destroy(result);
            if (subset != IntPtr.Zero) hb_face_destroy(subset);
            if (input != IntPtr.Zero) hb_subset_input_destroy(input);
            if (face != IntPtr.Zero) hb_face_destroy(face);
            if (blob != IntPtr.Zero) hb_blob_destroy(blob);
            handle.Free();
        }
    }
}
