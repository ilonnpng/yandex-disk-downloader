using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;
using YandexDiskDownloader.Core;

namespace YandexDiskDownloader.Windows;

internal static class SmokeScenario
{
    public static async Task Run(MainWindow window, Dispatcher dispatcher)
    {
        var temp = Path.Combine(Path.GetTempPath(), "YandexDisk-UI-Test-" + Guid.NewGuid());
        Directory.CreateDirectory(temp);
        var handler = new Fixture();
        using var model = new MainViewModel(dispatcher, new HttpClient(handler), false);
        window.DataContext = model;
        try
        {
            model.Link = "https://disk.yandex.ru/d/ci-sample"; model.Destination = temp; model.Parallelism = 1;
            await model.Inspect();
            Require(model.Files.Count == 2 && model.CanStart, "Inspection / button state");
            await model.Start(false);
            Require(model.Files.Count(x => x.State == FileState.Complete) == 1 && model.Files.Count(x => x.State == FileState.Failed) == 1 && model.CanRetry,
                "A failed first file must not stop the next file");
            await model.Start(true);
            Require(model.Files.All(x => x.State == FileState.Complete) && !model.CanRetry, "Manual retry");
            await model.Inspect(); await model.Start(false);
            Require(model.Files.All(x => x.State == FileState.Skipped), "Existing-file checksum verification");
            Require(Directory.GetFiles(temp, "*.mp3", SearchOption.AllDirectories).Length == 2, "No duplicate downloads");
        }
        finally
        {
            window.DataContext = new MainViewModel(dispatcher, persist: false);
            Directory.Delete(temp, true);
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Fixture : HttpMessageHandler
    {
        private readonly byte[] payload = Encoding.UTF8.GetBytes("Windows test download");
        private int failedAttempts;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); var uri = request.RequestUri!;
            if (uri.Host == "cloud-api.yandex.net")
            {
                if (uri.AbsolutePath.EndsWith("/download"))
                {
                    var failed = Uri.UnescapeDataString(uri.Query).Contains("first.mp3");
                    return Json(new DownloadLink("https://download.example/" + (failed ? "first" : "second"), "GET", false));
                }
                var hash = Convert.ToHexString(SHA256.HashData(payload));
                var files = new[] { new Resource("first.mp3", "file", "/first.mp3", payload.Length, null, hash, null), new Resource("second.mp3", "file", "/second.mp3", payload.Length, null, hash, null) };
                return Json(new Resource("CI sample", "dir", "/", null, null, null, new(files, 2, 0, 100)));
            }
            if (uri.Host == "download.example")
            {
                if (uri.AbsolutePath == "/first" && Interlocked.Increment(ref failedAttempts) == 1)
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(payload) });
            }
            throw new InvalidOperationException("Unexpected network access in smoke check");
        }
        private static Task<HttpResponseMessage> Json<T>(T value) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") });
    }
}
