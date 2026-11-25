import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import study_server


class StudyAPI(unittest.TestCase):
    def test_selected_text_payload_and_output(self):
        fragment = "return x * x"
        response = {"output": [{"type": "reasoning"}, {"type": "message", "content": [
            {"type": "output_text", "text": "Squares the numeric input."}]}]}
        with patch("study_server.urlopen", return_value=io.BytesIO(json.dumps(response).encode())) as request:
            result = study_server.explanation(fragment, "Code", "fixture-key")
        req = request.call_args.args[0]
        body = json.loads(req.data)
        self.assertEqual(req.full_url, "https://api.openai.com/v1/responses")
        self.assertEqual(body["input"], "Code\n\n" + fragment)
        self.assertFalse(body["store"])
        self.assertEqual(result, "Squares the numeric input.")

    def test_photographed_word_problem(self):
        crop = "data:image/jpeg;base64,/9j/2Q=="
        problem = "A cart rolls 24 m in 3 s. What is its average speed?"
        response = {"output":[{"type":"message","content":[{"type":"output_text","text":"24 m / 3 s = 8 m/s"}]}]}
        with patch("study_server.urlopen", return_value=io.BytesIO(json.dumps(response).encode())) as send:
            self.assertIn("8 m/s", study_server.explanation(problem,"Question","fixture-key",crop))
        body = json.loads(send.call_args.args[0].data)
        content = body["input"][0]["content"]
        self.assertIn(problem, content[0]["text"])
        self.assertEqual(content[1], {"type":"input_image","image_url":crop,"detail":"high"})
        self.assertFalse(body["store"])

    def test_empty_response_is_an_error(self):
        with patch("study_server.urlopen", return_value=io.BytesIO(b'{"output":[]}')):
            with self.assertRaises(ValueError):
                study_server.explanation("2 + 2", "Equation", "fixture-key")


if __name__ == "__main__":
    unittest.main()
