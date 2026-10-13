using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using YandexDiskDownloader.Core;
using YandexDiskDownloader.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
        var app = new App(); app.InitializeComponent();
        app.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(async () =>
        {
            try
            {
                await Verify((MainWindow)app.MainWindow, output);
                var live = await LiveProbe.Run();
                File.WriteAllText(Path.Combine(output, "live-results.txt"), live);
                Console.WriteLine(live);
                Console.WriteLine("PASS all published-Windows interface scenarios"); app.Shutdown(0);
            }
            catch (Exception error)
            {
                File.WriteAllText(Path.Combine(output, "failure.txt"), error.ToString());
                Console.Error.WriteLine(error); app.Shutdown(1);
            }
        }));
        return app.Run();
    }
    private static async Task Verify(MainWindow window, string output)
    {
        var temp = Path.Combine(Path.GetTempPath(), "Windows-App-QA-" + Guid.NewGuid()); Directory.CreateDirectory(temp);
        var fixture = new Fixture();
        using var model = new MainViewModel(window.Dispatcher, new HttpClient(fixture), false);
        window.DataContext = model;
        try
        {
            model.Link = "https://disk.yandex.ru/d/windows-ci-fixture"; model.Destination = temp; model.Parallelism = 1;
            await model.Inspect();
            Require(model.Files.Count == 4 && model.CanStart, "recursive inspection and download button");
            var pass = model.Start(false);
            await Until(() => model.Files.Any(x => x.State == FileState.Downloading && x.Bytes > 0));
            await Snapshot(window, output, "02-downloading.png");
            model.Pause(); await pass;
            Require(model.CanStart && !model.CanEdit && model.Files.Any(x => x.State == FileState.Paused && x.Bytes > 0), "pause retains partial bytes");
            await Snapshot(window, output, "03-paused.png");
            await model.Start(false);
            Require(fixture.RangeRequests > 0, "resume requests a partial HTTP range");
            Require(model.Files.Count(x => x.State == FileState.Complete) == 3 && model.Files.Count(x => x.State == FileState.Failed) == 1 && fixture.BadAttempts == 1,
                "failed first file is skipped without automatic retries");
            await model.Start(true);
            Require(model.Files.All(x => x.State == FileState.Complete) && fixture.BadAttempts == 2, "manual retry succeeds");
            await Snapshot(window, output, "04-completed.png");
            await model.Inspect(); await model.Start(false);
            Require(model.Files.All(x => x.State == FileState.Skipped) && Directory.GetFiles(temp, "*.mp3", SearchOption.AllDirectories).Length == 4,
                "existing files are verified and skipped without duplicates");
            await model.Inspect(); model.SkipExisting = false;
            var canceled = model.Start(false);
            await Until(() => model.Files.Any(x => x.State == FileState.Downloading && x.Bytes > 0));
            model.Cancel(); await canceled;
            Require(model.CanEdit && !model.CanCancel && Directory.GetFiles(temp, "*.mp3", SearchOption.AllDirectories).Length == 4,
                "cancel preserves completed files and discards partial work");
            await model.Start(false);
            Require(model.Files.All(x => x.State == FileState.Complete) && Directory.GetFiles(temp, "*.mp3", SearchOption.AllDirectories).Length == 8,
                "name collisions create numbered files without overwriting");
            foreach (var file in Directory.GetFiles(temp, "*.mp3", SearchOption.AllDirectories))
                Require(Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(file))) == fixture.Hash, "saved bytes match SHA-256");
        }
        finally { Directory.Delete(temp, true); }
    }
    private static void Require(bool condition, string name)
    { if (!condition) throw new InvalidOperationException("FAIL " + name); Console.WriteLine("PASS " + name); }
    private static async Task Until(Func<bool> condition)
    {
        var clock = Stopwatch.StartNew();
        while (!condition()) { if (clock.Elapsed.TotalSeconds > 20) throw new TimeoutException("Expected download state did not appear"); await Task.Delay(25); }
    }
    private static async Task Snapshot(MainWindow window, string output, string name)
    {
        await window.Dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.Render);
        var bounds = VisualTreeHelper.GetDescendantBounds(window);
        var image = new RenderTargetBitmap((int)Math.Ceiling(bounds.Right), (int)Math.Ceiling(bounds.Bottom), 96, 96, PixelFormats.Pbgra32);
        image.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(Path.Combine(output, name)); encoder.Save(file);
    }
    private sealed class Fixture : HttpMessageHandler
    {
        private readonly byte[] payload = Enumerable.Range(0, 262144).Select(x => (byte)(x % 251)).ToArray();
        public string Hash => Convert.ToHexString(SHA256.HashData(payload));
        public int BadAttempts;
        public int RangeRequests;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); var uri = request.RequestUri!;
            if (uri.Host == "cloud-api.yandex.net")
            {
                var query = Uri.UnescapeDataString(uri.Query);
                if (uri.AbsolutePath.EndsWith("/download"))
                {
                    var bad = query.Contains("01-error.mp3");
                    return Json(new DownloadLink("https://download.example/" + (bad ? "bad" : "good"), "GET", false));
                }
                Resource File(string name, string path) => new(name, "file", path, payload.Length, null, Hash, null);
                var sub = query.Contains("path=/sub");
                var items = sub ? new[] { File("03-track.mp3", "/sub/03-track.mp3"), File("04-track.mp3", "/sub/04-track.mp3") } :
                    new[] { File("01-error.mp3", "/01-error.mp3"), File("02-track.mp3", "/02-track.mp3"), new Resource("Подпапка", "dir", "/sub", null, null, null, null) };
                return Json(new Resource("Проверка Windows", "dir", "/", null, null, null, new(items, items.Length, 0, 100)));
            }
            if (uri.Host != "download.example") throw new InvalidOperationException("Unexpected external request in controlled test");
            if (uri.AbsolutePath == "/bad" && Interlocked.Increment(ref BadAttempts) == 1)
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
            var from = request.Headers.Range?.Ranges.Single().From ?? 0;
            if (from > 0) Interlocked.Increment(ref RangeRequests);
            var response = new HttpResponseMessage(from > 0 ? HttpStatusCode.PartialContent : HttpStatusCode.OK)
            { Content = new StreamContent(new SlowStream(payload, (int)from)) };
            response.Content.Headers.ContentLength = payload.Length - from;
            if (from > 0) response.Content.Headers.ContentRange = new ContentRangeHeaderValue(from, payload.Length - 1, payload.Length);
            return Task.FromResult(response);
        }
        private static Task<HttpResponseMessage> Json<T>(T value) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(JsonSerializer.Serialize(value)) });
    }
    private sealed class SlowStream(byte[] bytes, int start) : Stream
    {
        private int position = start;
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => bytes.Length; public override long Position { get => position; set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            await Task.Delay(20, token); var size = Math.Min(4096, Math.Min(buffer.Length, bytes.Length - position));
            bytes.AsMemory(position, size).CopyTo(buffer); position += size; return size;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) => ReadAsync(buffer.AsMemory(offset, count), token).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
