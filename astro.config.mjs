// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Site URL - defaults to prod, can be overridden by SITE_URL env var
const siteUrl = process.env.SITE_URL || 'https://rol.church';

// https://astro.build/config
export default defineConfig({
  site: siteUrl,
  integrations: [sitemap()],
});
