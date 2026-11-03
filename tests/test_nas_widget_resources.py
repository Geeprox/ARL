"""Keep the compiled resource identical to the tested standalone widget."""
import unittest
from integrations.nas import build_download_widget as widget


class WidgetResourceTests(unittest.TestCase):
    def test_compiled_static_resource_is_current(self):
        self.assertEqual(widget.TARGET.read_text(), widget.source())

    def test_resource_needs_no_external_script_or_network_fetch(self):
        html=widget.html()
        self.assertNotIn('<script src=',html)
        self.assertNotIn('fetch(',html.replace('No fetch(),',''))
        self.assertIn('"ui/initialize"',html)
        self.assertIn('"ui/notifications/initialized"',html)
        self.assertIn('platform.uploadFile(file, {library:false})',html)
        self.assertNotIn('library:true',html)
        self.assertIn('platform.getFileDownloadUrl({fileId:this.fileId})',html)


if __name__=="__main__":unittest.main()
