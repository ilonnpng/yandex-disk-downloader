using System.IO;
using YandexDiskDownloader.Core;

internal static class LiveProbe
{
    public static async Task<string> Run()
    {
        // Public sample links published by SDK/archive authors, not user data.
        // https://github.com/ufee/yandex-disk (public-resource SDK example)
        // https://github.com/ruarxive/ydiskarc/blob/main/examples/METADATA_STRUCTURE.md
        var links = new[] { "https://yadi.sk/d/g0N4hNtXcrq22", "https://yadi.sk/d/4Z0GsDwfR4gkPA" };
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        using var client = DiskApi.CreateClient(); var api = new DiskApi(client);
        var observations = new List<string>();
        foreach (var link in links)
        {
            try
            {
                var key = PublicLink.Validate(link);
                var resource = await api.Resource(key, null, 0, 100, timeout.Token);
                observations.Add("LIVE API metadata: PASS");
                Resource? candidate = resource.Type == "file" ? resource : Pick(resource);
                if (candidate == null && resource.Embedded != null)
                {
                    var folder = resource.Embedded.Items.FirstOrDefault(x => x.Type == "dir" && x.Path != null);
                    if (folder != null) candidate = Pick(await api.Resource(key, folder.Path, 0, 100, timeout.Token));
                }
                if (candidate?.Size is not (>= 0 and <= 2_000_000)) { observations.Add("LIVE sample: no small downloadable file in first pages"); continue; }
                var file = new RemoteFile(resource.Type == "file" ? null : candidate.Path, [SafeNames.Local(candidate.Name)], candidate.Size, candidate.Md5, candidate.Sha256);
                if (resource.Type != "file" && file.ApiPath == null) continue;
                var url = await api.DownloadUrl(key, file.ApiPath, timeout.Token);
                using var partial = new PartialTransfer();
                await new FileTransfer(client).Download(url, file, partial, _ => { }, timeout.Token);
                await FileTransfer.Verify(partial.Stream, file, true, timeout.Token);
                var hash = file.Sha256 != null ? "SHA-256" : file.Md5 != null ? "MD5" : "no checksum supplied by API";
                observations.Add($"LIVE Yandex download: PASS; {partial.Stream.Length} bytes; size verified; {hash}");
                return string.Join(Environment.NewLine, observations);
            }
            catch (Exception error)
            {
                observations.Add("LIVE sample unavailable: " + ErrorText.Safe(error));
                if (timeout.IsCancellationRequested) break;
            }
        }
        observations.Add("LIVE complete download: NOT VERIFIED (sample availability / network)");
        return string.Join(Environment.NewLine, observations);
    }
    private static Resource? Pick(Resource directory) => directory.Embedded?.Items
        .Where(x => x.Type == "file" && x.Size is >= 0 and <= 2_000_000).OrderBy(x => x.Size).FirstOrDefault();
}
