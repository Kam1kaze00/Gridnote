#!/usr/bin/env python3
"""Build the offline standalone app using integrity-pinned, locally hosted PDF libraries."""
import base64
import hashlib
import io
import json
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source_files = """
    ink-materials.mjs writer-grain.mjs image-size.mjs app.mjs blocks.mjs camera.mjs devices.mjs engine.mjs eraser.mjs
    guide.html index.html launcher.html launcher.css launcher.js manifest.webmanifest pages.mjs render.mjs
    solver.js store.mjs study-geometry.mjs study.mjs style.css
""".split()
source_files += [p.relative_to(root / "web").as_posix() for p in sorted((root / "web/assets").glob("*")) if p.is_file() and not p.name.startswith(".")]
packages = {
    'pdfjs-dist': ('5.6.205', 'tlUj+2IDa7G1SbvBNN74UHRLJybZDWYom+k6p5KIZl7huBvsA4APi6mKL+zCxd3tLjN5hOOEE9Tv7VdzO88pfg=='),
    'tesseract.js': ('7.0.0','exPBkd+z+wM1BuMkx/Bjv43OeLBxhL5kKWsz/9JY+DXcXdiBjiAch0V49QR3oAJqCaL5qURE0vx9Eo+G5YE7mA=='),
    'tesseract.js-core': ('7.0.0','WnNH518NzmbSq9zgTPeoF8c+xmilS8rFIl1YKbk/ptuuc7p6cLNELNuPAzcmsYw450ca6bLa8j3t0VAtq435Vw=='),
    '@tesseract.js-data/eng': ('1.0.0','mbTumm6KQPUHyzTPQaF3ObXYnx0SqqfV2nabqFVQBwD6Kl7PhGSLSzOlfFTWy0P3BjghaSKA2W9GB19Jk+ZcTg=='),
    'pdf-lib': ('1.17.1', 'V/mpyJAoTsN4cnP31vc0wfNA1+p20evqqnap0KLoRUN0Yk/p3wN52DOEsL4oBFcLdb76hlpKPtzJIgo67j/XLw==')
}


def build(destination, cache):
    for name in source_files:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / 'web' / name, target)
    vendor = destination / 'vendor'
    vendor.mkdir()
    cache.mkdir(exist_ok=True)
    for name, (version, integrity) in packages.items():
        short = name.split('/')[-1]
        archive = cache / f'{short}-{version}.tgz'
        if not archive.exists():
            url = f'https://registry.npmjs.org/{name}/-/{short}-{version}.tgz'
            with urllib.request.urlopen(url) as response:
                archive.write_bytes(response.read())
        data = archive.read_bytes()
        if base64.b64encode(hashlib.sha512(data).digest()).decode() != integrity:
            raise SystemExit(f'Integrity check failed for {name}')
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
            for member in tar:
                if not member.isfile() or not member.name.startswith('package/'):
                    continue
                path = member.name[8:]
                if '..' in Path(path).parts or Path(path).is_absolute():
                    raise SystemExit('Invalid archive path')
                mapping = {'legacy/build/pdf.min.mjs':'pdf.mjs', 'legacy/build/pdf.worker.min.mjs':'pdf.worker.mjs',
                           'dist/pdf-lib.esm.min.js':'pdf-lib.mjs', 'LICENSE':name+'-LICENSE', 'LICENSE.md':name+'-LICENSE.md'}
                target = mapping.get(path)
                if name == 'pdfjs-dist' and path.startswith(('cmaps/', 'standard_fonts/', 'wasm/', 'iccs/')):
                    target = path
                if name == 'tesseract.js' and path in ('dist/tesseract.min.js','dist/worker.min.js'):
                    target = 'ocr/' + path.split('/')[-1]
                if name == 'tesseract.js-core' and path in ('tesseract-core-lstm.js','tesseract-core-lstm.wasm'):
                    target = 'ocr/' + path
                if name == '@tesseract.js-data/eng' and path == '4.0.0_best_int/eng.traineddata.gz':
                    target = 'ocr/eng.traineddata.gz'
                if target:
                    file = vendor / target
                    file.parent.mkdir(exist_ok=True)
                    file.write_bytes(tar.extractfile(member).read())
    shutil.copyfile(root / 'LICENSE', destination / 'LICENSE')
    shutil.copyfile(root / 'scripts' / 'licenses' / 'eng-data-LICENSE', vendor / 'eng-traineddata-LICENSE')
    files = sorted(p for p in destination.rglob('*') if p.is_file() and p.name not in ('sw.js', '.DS_Store'))
    revision = hashlib.sha256()
    for path in files:
        revision.update(path.relative_to(destination).as_posix().encode())
        revision.update(path.read_bytes())
    urls = ['./' + p.relative_to(destination).as_posix() for p in files]
    worker = """
const name='gridnote-'+REVISION;
const scope=self.registration.scope;
const prefix='gridnote-'+new URL(scope).pathname+':';
const cacheKey=prefix+name;
self.addEventListener('install',event=>event.waitUntil((async()=>{
  const cache=await caches.open(cacheKey);
  const list=FILES;
  try {
    for(let i=0;i<list.length;i+=12){
      const batch=list.slice(i,i+12).map(url=>new Request(url,{cache:'reload'}));
      await cache.addAll(batch);
    }
  } catch(error) {
    await caches.delete(cacheKey);
    throw error;
  }
  await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  for(const key of await caches.keys())if(key.startsWith(prefix)&&key!==cacheKey)await caches.delete(key);
  await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET'||!event.request.url.startsWith(scope))return;
  event.respondWith((async()=>{
    const cache=await caches.open(cacheKey);
    const request=event.request;
    if(request.mode==='navigate'){
      const url=new URL(request.url);
      if(url.pathname===new URL(scope).pathname)url.pathname+='index.html';
      url.search='';url.hash='';
      const page=await cache.match(url);
      if(!page)return fetch(request);
      // File servers can canonicalize /index.html to /. Navigation requests
      // use manual redirect mode, so return the final cached document body.
      if(page.redirected)return new Response(page.body,{status:page.status,statusText:page.statusText,headers:page.headers});
      return page;
    }
    return (await cache.match(request)) || fetch(request);
  })());
});
"""
    revision.update(worker.encode())
    (destination / 'sw.js').write_text(worker.replace('REVISION',json.dumps(revision.hexdigest()[:16])).replace('FILES',json.dumps(urls)))
    return len(files)


def publish(destination):
    source = root / 'web'
    if destination == source or source in destination.parents or destination in source.parents:
        raise SystemExit('Choose a separate build directory.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
        stage = Path(scratch) / 'site'
        stage.mkdir()
        count = build(stage, destination.parent / '.gridnote-build-cache')
        if destination.exists():
            if destination.is_symlink() or not destination.is_dir():
                raise SystemExit('The destination must be a build directory.')
            # An earlier build's offline file list identifies its retired assets.
            manifest = destination / 'sw.js'
            managed = set()
            if manifest.is_file() and not manifest.is_symlink():
                for line in manifest.read_text().splitlines():
                    if line.startswith('  const list=') and line.endswith(';'):
                        managed = set(json.loads(line.split('=', 1)[1][:-1]))
                        break
            for path in destination.rglob('*'):
                relative = path.relative_to(destination)
                expected = stage / relative
                old = './' + relative.as_posix()
                known = old in managed if path.is_file() else any(f.startswith(old + '/') for f in managed)
                if path.is_symlink() or not (known or expected.exists()) or (expected.exists() and path.is_file() != expected.is_file()):
                    raise SystemExit(f'Output contains an unrelated entry: {relative}. Choose an empty directory.')
            previous = Path(scratch) / 'previous'
            destination.rename(previous)
            try:
                stage.rename(destination)
            except OSError:
                if not destination.exists():
                    previous.rename(destination)
                raise
        else:
            stage.rename(destination)
    print(f'Built {count} offline assets in {destination}')


if __name__ == '__main__':
    publish(Path(sys.argv[1] if len(sys.argv) > 1 else root / 'build' / 'standalone').resolve())
