using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace YandexDiskDownloader.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
        if (e.Args.Length == 2 && e.Args[0] == "--smoke")
        {
            // CI-only layout smoke check, no network or downloads.
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
            {
                try
                {
                    window.UpdateLayout();
                    if (window.ActualWidth < 900 || window.ActualHeight < 600 || window.DataContext is not MainViewModel)
                        throw new InvalidOperationException("Window did not load correctly.");
                    var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(window);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var output = File.Create(e.Args[1]); encoder.Save(output);
                    Shutdown(0);
                }
                catch { Shutdown(1); }
            }));
        }
    }
}
