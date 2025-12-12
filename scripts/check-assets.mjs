#!/usr/bin/env node
/**
 * Build-time asset checker
 *
 * Scans all built HTML files for references to local assets
 * and verifies they exist in the dist folder.
 */

import { readdir, readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { existsSync } from 'fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const distDir = join(__dirname, '..', 'dist');

// Patterns to find local asset references
const assetPatterns = [
  /src="(\/[^"]+)"/g,
  /href="(\/[^"]+\.(css|js|png|jpg|jpeg|webp|svg|ico|pdf|woff2?|ttf|eot))"/g,
  /srcset="([^"]+)"/g,
  /url\(['"]?(\/[^'")]+)['"]?\)/g,
];

// External patterns to ignore
const ignorePatterns = [
  /^https?:\/\//,
  /^\/\//,
  /^data:/,
  /^#/,
  /^mailto:/,
  /^tel:/,
  /churchcenter\.com/,
  /planningcenteronline\.com/,
];

async function getAllHtmlFiles(dir) {
  const files = [];
  const entries = await readdir(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await getAllHtmlFiles(fullPath));
    } else if (entry.name.endsWith('.html')) {
      files.push(fullPath);
    }
  }

  return files;
}

function extractAssets(content) {
  const assets = new Set();

  for (const pattern of assetPatterns) {
    const regex = new RegExp(pattern.source, pattern.flags);
    let match;
    while ((match = regex.exec(content)) !== null) {
      // Handle srcset which can have multiple URLs
      if (match[0].includes('srcset')) {
        const srcsetParts = match[1].split(',');
        for (const part of srcsetParts) {
          const url = part.trim().split(/\s+/)[0];
          if (url.startsWith('/')) {
            assets.add(url);
          }
        }
      } else {
        const url = match[1];
        if (url && url.startsWith('/')) {
          assets.add(url);
        }
      }
    }
  }

  return assets;
}

function shouldIgnore(url) {
  return ignorePatterns.some(pattern => pattern.test(url));
}

function stripQueryString(url) {
  return url.split('?')[0];
}

async function main() {
  console.log('Checking for missing assets...\n');

  if (!existsSync(distDir)) {
    console.error('Error: dist directory not found. Run `npm run build` first.');
    process.exit(1);
  }

  const htmlFiles = await getAllHtmlFiles(distDir);
  const missingAssets = new Map(); // asset -> [pages that reference it]
  const checkedAssets = new Set();

  for (const htmlFile of htmlFiles) {
    const content = await readFile(htmlFile, 'utf-8');
    const assets = extractAssets(content);
    const relativePage = htmlFile.replace(distDir, '');

    for (const asset of assets) {
      const cleanAsset = stripQueryString(asset);

      if (shouldIgnore(cleanAsset) || checkedAssets.has(cleanAsset)) {
        continue;
      }

      checkedAssets.add(cleanAsset);

      // Check if asset exists
      const assetPath = join(distDir, cleanAsset);
      if (!existsSync(assetPath)) {
        if (!missingAssets.has(cleanAsset)) {
          missingAssets.set(cleanAsset, []);
        }
        missingAssets.get(cleanAsset).push(relativePage);
      }
    }
  }

  if (missingAssets.size === 0) {
    console.log(`✓ All ${checkedAssets.size} local assets verified.\n`);
    process.exit(0);
  } else {
    console.error(`✗ Found ${missingAssets.size} missing asset(s):\n`);
    for (const [asset, pages] of missingAssets) {
      console.error(`  ${asset}`);
      console.error(`    Referenced in: ${pages[0]}`);
      if (pages.length > 1) {
        console.error(`    (and ${pages.length - 1} other page(s))`);
      }
    }
    console.error('');
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
