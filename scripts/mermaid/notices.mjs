import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const lock = JSON.parse(fs.readFileSync(path.join(here, 'package-lock.json'), 'utf8'));
const sections = ['Licenses for the bundled Mermaid renderer and its npm dependencies.'];

for (const [packagePath, metadata] of Object.entries(lock.packages).sort(([a], [b]) => a.localeCompare(b))) {
  if (!packagePath) continue;
  const directory = path.join(here, packagePath);
  if (!fs.existsSync(path.join(directory, 'package.json'))) continue;
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
  const licenseFile = fs.readdirSync(directory)
    .filter(name => /^(license|licence|copying|notice)(\..*)?$/i.test(name))
    .sort((a, b) => a.length - b.length)[0];
  const license = licenseFile
    ? fs.readFileSync(path.join(directory, licenseFile), 'utf8').trim()
    : `License: ${manifest.license || metadata.license || 'see package metadata'}`;
  sections.push(`\n${manifest.name} ${manifest.version}\n${'-'.repeat(72)}\n${license}`);
}

const output = path.resolve(here, '../../Sources/Typeflux/Resources/ThirdPartyNotices-Mermaid.txt');
const normalize = text => text.replace(/\r\n?/g, '\n').replace(/[ \t]+$/gm, '');
fs.writeFileSync(output, normalize(sections.join('\n')) + '\n');

const legalPath = path.resolve(here, '../../Sources/Typeflux/Resources/mermaid.bundle.js.LEGAL.txt');
fs.writeFileSync(legalPath, normalize(fs.readFileSync(legalPath, 'utf8')));
