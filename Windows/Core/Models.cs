using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace YandexDiskDownloader.Core;

public static class PublicLink
{
    private static readonly HashSet<string> Hosts = new(StringComparer.OrdinalIgnoreCase)
        { "disk.yandex.ru", "disk.yandex.com", "disk.yandex.kz", "disk.yandex.by", "disk.yandex.com.tr", "yadi.sk" };
    public static string Validate(string input)
    {
        var text = input.Trim();
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            !Hosts.Contains(uri.Host) || uri.UserInfo.Length != 0 || !uri.IsDefaultPort)
            throw new InvalidDataException("Нужна публичная HTTPS-ссылка Яндекс Диска.");
        var parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts[0] is not ("d" or "i" or "public"))
            throw new InvalidDataException("Нужна ссылка на публичный файл или папку.");
        return new UriBuilder(uri) { Fragment = "" }.Uri.AbsoluteUri;
    }
}

public sealed record Resource(string Name, string Type, string? Path, long? Size, string? Md5, string? Sha256,
    [property: JsonPropertyName("_embedded")] Listing? Embedded);
public sealed record Listing(Resource[] Items, int? Total, int? Offset, int? Limit);
public sealed record DownloadLink(string Href, string? Method, bool? Templated);
public sealed record RemoteFile(string? ApiPath, string[] Components, long? Size, string? Md5, string? Sha256);
public sealed record Manifest(string Name, List<RemoteFile> Files, List<string[]> Directories, List<string> Warnings)
{
    public long TotalSize => Files.Sum(x => Math.Max(0, x.Size ?? 0));
    public bool KnownSize => Files.All(x => x.Size is >= 0);
}

public static class SafeNames
{
    public static void ValidateRemote(string name)
    {
        if (string.IsNullOrEmpty(name) || name is "." or ".." || name.Contains('/') || name.Contains('\0'))
            throw new InvalidDataException("Небезопасное имя файла.");
    }
    public static void ValidateApiPath(string path)
    {
        if (!path.StartsWith('/') || path.Contains('\0')) throw new InvalidDataException("Некорректный API-путь.");
        if (path != "/") foreach (var part in path[1..].Split('/')) ValidateRemote(part);
    }
    public static string Local(string remote)
    {
        ValidateRemote(remote);
        var name = new string(remote.Select(c => c < 32 || c == 127 || "<>:\"/\\|?*".Contains(c) ? '_' : c).ToArray())
            .Normalize(NormalizationForm.FormC).TrimEnd(' ', '.');
        if (name.Length == 0 || name is "." or "..") name = "_";
        var device = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        if (device is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$" or "CLOCK$" ||
            (device.Length == 4 && (device.StartsWith("COM") || device.StartsWith("LPT")) && "123456789¹²³".Contains(device[3])))
            name = "_" + name;
        if (name.Length > 180)
        {
            var extension = System.IO.Path.GetExtension(name);
            if (extension.Length > 24) extension = "";
            var prefix = name[..Math.Min(155, name.Length - extension.Length)];
            if (char.IsHighSurrogate(prefix[^1])) prefix = prefix[..^1];
            name = prefix + "-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(remote)))[..12].ToLowerInvariant() + extension;
        }
        return name;
    }
    public static string Reserve(string name, HashSet<string> used)
    {
        for (var i = 0; i <= 10000; i++)
        {
            var candidate = Numbered(name, i);
            if (used.Add(candidate.Normalize(NormalizationForm.FormC))) return candidate;
        }
        throw new IOException("Слишком много совпадающих имён.");
    }
    public static string Numbered(string name, int i) => i == 0 ? name :
        System.IO.Path.GetFileNameWithoutExtension(name) + $" ({i})" + System.IO.Path.GetExtension(name);
}

public sealed class HttpStatusException(int status, TimeSpan? retryAfter = null) : IOException($"HTTP {status}")
{
    public int Status { get; } = status;
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

public static class ErrorText
{
    // Exception messages from HTTP clients can contain signed URLs. Keep errors generic.
    public static string Safe(Exception error) => error switch
    {
        HttpStatusException e => $"HTTP {e.Status}: ошибка сервера или ограничение доступа.",
        HttpRequestException => "Ошибка сети. Файл пропущен; его можно повторить позже.",
        OperationCanceledException => "Операция отменена или соединение слишком долго не отвечает.",
        UnauthorizedAccessException => "Нет доступа к выбранной папке.",
        InvalidDataException e => e.Message,
        _ => "Ошибка записи или обработки файла. Проверьте место на диске и доступ к папке."
    };
}
