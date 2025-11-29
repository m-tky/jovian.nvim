import io
import json
import sys


class StreamCapture:
    def __init__(self, stream_name, callback):
        self.stream_name = stream_name
        self.callback = callback
        self.buffer = io.StringIO()

    def write(self, text):
        self.buffer.write(text)
        self.callback(self.stream_name, text)

    def flush(self):
        pass

    def get_value(self):
        return self.buffer.getvalue()

    def reset(self):
        self.buffer.truncate(0)
        self.buffer.seek(0)


def send_json(data):
    sys.__stdout__.write(json.dumps(data) + "\n")
    sys.__stdout__.flush()


def send_stream(stream_name, text, cell_id="unknown"):
    send_json(
        {"type": "stream", "stream": stream_name, "text": text, "cell_id": cell_id}
    )
