using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace YandexDiskDownloader.Windows;

public partial class App : Application
{
    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, error) => SmokeError(error.ExceptionObject.ToString() ?? "Startup failure");
        DispatcherUnhandledException += (_, error) =>
        {
            if (Environment.GetCommandLineArgs().Skip(1).FirstOrDefault() != "--smoke") return;
            SmokeError(error.Exception.ToString()); error.Handled = true; Shutdown(1);
        };
    }
    private static void SmokeError(string error)
    {
        var args = Environment.GetCommandLineArgs();
        if (args.Length == 3 && args[1] == "--smoke") File.WriteAllText(args[2] + ".error.txt", error);
    }
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
        if (e.Args.Length == 2 && e.Args[0] == "--smoke")
        {
            // CI-only layout smoke check, no network or downloads.
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(async () =>
            {
                try
                {
                    await SmokeScenario.Run(window, Dispatcher);
                    window.UpdateLayout();
                    if (window.ActualWidth < 900 || window.ActualHeight < 600 || window.DataContext is not MainViewModel)
                        throw new InvalidOperationException("Window did not load correctly.");
                    var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(window);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var output = File.Create(e.Args[1]); encoder.Save(output);
                    Shutdown(0);
                }
                catch (Exception error)
                {
                    File.WriteAllText(e.Args[1] + ".error.txt", error.ToString());
                    Shutdown(1);
                }
            }));
        }
    }
}
