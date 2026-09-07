"""Run the installed Mimir outside its source tree and read the global skill."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []
failures = []


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        try:
            if len(requests) == 1:
                assert 'configure-mimir' in json.dumps(body), 'global skill missing from catalog'
                delta = {'tool_calls': [{'index': 0, 'id': 'read-installed-skill', 'type': 'function',
                                        'function': {'name': 'read_skill', 'arguments': json.dumps({
                                            'name': 'configure-mimir',
                                            'path': 'references/settings-and-precedence.md',
                                        })}}]}
                reason = 'tool_calls'
            else:
                results = [message.get('content') for message in body['messages']
                           if message.get('tool_call_id') == 'read-installed-skill']
                assert results and 'model.thinkingEffort' in str(results[-1]), 'installed reference was not read'
                delta, reason = {'content': 'Installed skill verified.'}, 'stop'
            output = ('data: ' + json.dumps({'choices': [{'delta': delta, 'finish_reason': reason}]})
                      + '\n\ndata: [DONE]\n\n').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(output)))
            self.end_headers()
            self.wfile.write(output)
        except Exception as error:
            failures.append(str(error))
            self.send_error(500)


with tempfile.TemporaryDirectory(prefix='mimir-installed-skill-') as directory:
    root = Path(directory)
    agent = root / 'agent'
    agent.mkdir()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (agent / 'settings.json').write_text(json.dumps({
        'defaultProvider': 'install-test', 'defaultModel': 'offline',
        'classifier': {'provider': 'missing-classifier', 'model': 'missing'},
    }))
    (agent / 'models.json').write_text(json.dumps({'providers': {'install-test': {
        'name': 'Installer test', 'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
        'api': 'openai-chat-completions', 'auth': 'none',
        'models': {'offline': {'name': 'Offline', 'limit': {'context': 128000}, 'input': ['text']}},
    }}}))
    env = dict(os.environ, MIMIR_CODING_AGENT_DIR=str(agent),
               MIMIR_MODELS_PATH=str(root / 'catalog.json'), MIMIR_DISABLE_MODELS_FETCH='1')
    try:
        result = subprocess.run([sys.argv[1], 'run', '--output', 'jsonl',
                                 'Read the installed configure-mimir settings reference.'],
                                cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert not failures, failures
        assert len(requests) == 2, len(requests)
        assert 'Installed skill verified.' in result.stdout
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
print('PASS installed global skill discovered and reference read through real Mimir')
