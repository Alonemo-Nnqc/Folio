namespace Folio.Core;

/// <summary>
/// How much a reading of a page looks like text. Windows' OCR does not say how sure it is, and reads something into a page lying
/// on its side, or into English with the Chinese reader: what comes out is as many characters, but no words. Sentences have the
/// little words of their language, and Chinese is mostly its commonest characters.
/// </summary>
public static class OcrQuality
{
    public readonly record struct Reading(int Letters, int Han, double Quality)
    {
        /// <summary>Characters, each counting as much as the reading looks like text.</summary>
        public double Score => (Letters + Han) * Quality;
        public bool IsLatin => Han * 10 < (Letters + Han) * 3;
        /// <summary>Too little to tell, or plainly text.</summary>
        public bool IsText => Letters + Han >= 40 && Quality >= 0.4;
    }

    const string CommonHan =
        "的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处"
        + "這個國時來們對會發動種過說產後學經進電裡現實兩機當點從業開還與關線內數問題無係軍想黨員總設長資邊統較將組見計別運農區決戰則據處";

    static readonly HashSet<string> LittleWords = new((
        "the of and to in is for that with on as by are this we be from an it or at was were which can has have our their not these its also " +
        "de la le les et des du en un une est que pour dans sur par au der die das und ist von den mit zu im für auf eine ein des dem nicht " +
        "el los las y del se con una por es al como lo il di che per non sono gli o os da em um uma não").Split(' '));

    public static Reading Of(IEnumerable<OcrLine> lines)
    {
        int letters = 0, han = 0, common = 0, words = 0, little = 0;
        foreach (var line in lines)
        {
            foreach (var token in line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                int run = 0;
                foreach (var c in token)
                {
                    if (c is >= '一' and <= '鿿') { han++; if (CommonHan.Contains(c)) common++; }
                    else if (char.IsLetter(c)) run++;
                }
                letters += run;
                var word = token.Trim('.', ',', ';', ':', '(', ')', '[', ']', '"', '\'', '“', '”', '，', '。');
                if (run < 2 || word.Length != run) continue;
                words++;
                if (LittleWords.Contains(word.ToLowerInvariant())) little++;
            }
        }
        if (letters + han == 0) return new Reading(0, 0, 0);
        double latin = words == 0 ? 0 : Math.Min(1, (double)little / words / 0.2), chinese = han == 0 ? 0 : Math.Min(1, (double)common / han / 0.4);
        return new Reading(letters, han, (letters * latin + han * chinese) / (letters + han));
    }

    /// <summary>Words that came apart into pieces lying edge to edge ("provi d ed": the Chinese reader does that to English).</summary>
    public static OcrLine Joined(OcrLine line)
    {
        if (line.Words.Count < 2) return line;
        double height = line.Words.Max(w => w.Height);
        var words = new List<OcrWord> { line.Words[0] };
        foreach (var next in line.Words.Skip(1))
        {
            var last = words[^1];
            double gap = next.X - (last.X + last.Width);
            if (gap < height * 0.12 && gap > -height * 0.5 && IsLatin(last.Text[^1]) && IsLatin(next.Text[0]))
            {
                double top = Math.Min(last.Y, next.Y), bottom = Math.Max(last.Y + last.Height, next.Y + next.Height);
                words[^1] = new OcrWord(last.Text + next.Text, last.X, top, next.X + next.Width - last.X, bottom - top);
            }
            else words.Add(next);
        }
        return line with { Words = words };
    }

    static bool IsLatin(char c) => char.IsLetterOrDigit(c) && c < 0x2E80;
}
