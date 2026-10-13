using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace YandexDiskDownloader.Core;

public sealed class PartialTransfer : IDisposable
{
    public FileStream Stream { get; }
    public PartialTransfer()
    {
        // CreateNew + a held handle: a preexisting file is never opened as staging.
        Stream = new FileStream(Path.Combine(Path.GetTempPath(), "YandexDiskDownloader-" + Guid.NewGuid() + ".part"),
            FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 131072,
            FileOptions.Asynchronous | FileOptions.DeleteOnClose);
    }
    public void Dispose() => Stream.Dispose();
}

public sealed class FileTransfer(HttpClient client, TimeSpan? stallTimeout = null)
{
    private readonly TimeSpan timeout = stallTimeout ?? TimeSpan.FromSeconds(45);
    public async Task Download(Uri uri, RemoteFile file, PartialTransfer partial, Action<long> progress, CancellationToken token)
    {
        if (uri.Scheme != "https") throw new InvalidDataException("Разрешены только HTTPS-загрузки.");
        var output = partial.Stream;
        var offset = output.Length;
        if (offset > 0 && file.Size == offset) { progress(offset); return; }
        using var response = await Send(uri, offset, token);
        if (!response.IsSuccessStatusCode) throw new HttpStatusException((int)response.StatusCode, DiskApi.RetryAfter(response));
        if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            var range = response.Content.Headers.ContentRange;
            if (range?.From != offset || range.Unit != "bytes" ||
                (file.Size != null && range.Length != file.Size))
                throw new InvalidDataException("Некорректный диапазон возобновления загрузки.");
        }
        else if (response.StatusCode == HttpStatusCode.OK)
        { output.SetLength(0); offset = 0; }
        else throw new InvalidDataException("Неожиданный ответ загрузки.");
        output.Position = offset;
        progress(offset);
        await using var input = await response.Content.ReadAsStreamAsync(token);
        var buffer = new byte[131072];
        while (true)
        {
            using var watchdog = CancellationTokenSource.CreateLinkedTokenSource(token);
            watchdog.CancelAfter(timeout);
            var count = await input.ReadAsync(buffer, watchdog.Token);
            if (count == 0) break;
            await output.WriteAsync(buffer.AsMemory(0, count), token);
            if (file.Size is { } size && output.Length > size) throw new InvalidDataException("Размер загрузки превышает исходный.");
            progress(output.Length);
        }
        await output.FlushAsync(token);
    }
    private async Task<HttpResponseMessage> Send(Uri uri, long offset, CancellationToken token)
    {
        // Follow redirects explicitly to reject HTTPS -> HTTP downgrade.
        for (var i = 0; i <= 10; i++)
        {
            if (uri.Scheme != "https" || uri.UserInfo.Length != 0) throw new InvalidDataException("Небезопасное перенаправление.");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
            using var watchdog = CancellationTokenSource.CreateLinkedTokenSource(token);
            watchdog.CancelAfter(timeout);
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, watchdog.Token);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                var next = response.Headers.Location;
                response.Dispose();
                if (next == null) throw new InvalidDataException("Пустое перенаправление.");
                uri = next.IsAbsoluteUri ? next : new Uri(uri, next);
                continue;
            }
            return response;
        }
        throw new InvalidDataException("Слишком много перенаправлений.");
    }
    public static async Task Verify(Stream stream, RemoteFile file, bool hashes, CancellationToken token)
    {
        if (file.Size is { } size && stream.Length != size) throw new InvalidDataException("Размер файла не совпадает с исходным.");
        if (!hashes) return;
        var expected = file.Sha256 ?? file.Md5;
        if (expected == null) return;
        stream.Position = 0;
        byte[] hash = file.Sha256 != null ? await SHA256.HashDataAsync(stream, token) : await MD5.HashDataAsync(stream, token);
        if (!Convert.ToHexString(hash).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Контрольная сумма файла не совпадает.");
    }
}
