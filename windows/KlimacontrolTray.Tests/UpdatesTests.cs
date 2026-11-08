using Xunit;

namespace KlimacontrolTray.Tests;

/// Der Test-Umweg für den Update-Feed (KLIMACONTROL_UPDATE_TEST_FEED) darf nur lokale Loopback-Adressen annehmen.
public class UpdatesTests
{
    [Theory]
    [InlineData("http://127.0.0.1:8765/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:1/")]
    [InlineData("http://127.0.0.1:65535/a/b_c-d.1/updateinfo-win.xml")]
    public void TestFeedAngenommen(string value) => Assert.Equal(value, Updates.TestFeedOverride(value));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("https://github.com/mlafx/Klimacontrol/releases/latest/download/updateinfo-win.xml")]
    [InlineData("http://localhost:8765/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1.evil.com/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1.evil.com:8765/updateinfo-win.xml")]
    [InlineData("http://127.0.0.10:8765/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1/")]
    [InlineData("https://127.0.0.1:8765/updateinfo-win.xml")]
    [InlineData("file:///C:/feed/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:0/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:65536/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:99999/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:123456/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:8765/update info.xml")]
    [InlineData("http://127.0.0.1:8765/updateinfo-win.xml ")]
    [InlineData(" http://127.0.0.1:8765/updateinfo-win.xml")]
    [InlineData("http://127.0.0.1:8765/updateinfo-win.xml\n")]
    [InlineData("http://127.0.0.1:8765/x?y=1")]
    public void TestFeedAbgelehnt(string? value) => Assert.Null(Updates.TestFeedOverride(value));
}
