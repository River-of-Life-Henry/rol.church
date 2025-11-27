# River of Life Church Website

The official website for River of Life Church in Henry, IL. Built with [Astro](https://astro.build).

**Live site:** [rol.church](https://rol.church)

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build
```

## Updating Content

Content is managed through **Planning Center** and synced to the website automatically.

### Where to Update Content in Planning Center

#### Events
1. Go to [planningcenter.com](https://planningcenter.com) → **Calendar**
2. Create or edit an event
3. Make sure the event is:
   - **Visible in Church Center** (checked)
   - Not tagged as "Hidden"
4. Events sync automatically daily at 6 AM CT, or run `ruby scripts/sync_events.rb`

#### Groups/Ministries
1. Go to Planning Center → **Groups**
2. Create or edit a group
3. Make sure **Church Center Visible** is enabled
4. Add group leaders via **Members** → set role to "Leader"
5. Upload a header image for the group page
6. Run `ruby scripts/sync_groups.rb` to sync

#### Team Members
1. Go to Planning Center → **People**
2. Find the person and go to their profile
3. Go to the **Website - ROL.Church** tab (custom field tab)
4. Set their **Position Title** (e.g., "Pastor", "Worship Leader")
5. Run `ruby scripts/sync_team.rb` to sync
6. Note: Couples in the same household with position titles are automatically combined

#### Hero Slider Images
1. Go to Planning Center → **Media**
2. Find the Website Hero Images album
3. Upload new images or reorder existing ones
4. Run `ruby scripts/sync_hero_images.rb` to sync

### Sync Data from Planning Center

To manually sync data:

```bash
cd scripts
bundle install  # First time only
ruby sync_all.rb
```

This requires Planning Center API credentials set as environment variables:
- `ROL_PLANNING_CENTER_CLIENT_ID`
- `ROL_PLANNING_CENTER_SECRET`

For local development, create a `.env` file in the `scripts/` directory with these values.

### Individual Sync Scripts

```bash
cd scripts

# Sync just events
ruby sync_events.rb

# Sync groups/ministries
ruby sync_groups.rb

# Sync team members
ruby sync_team.rb

# Sync hero images
ruby sync_hero_images.rb
```

### Automatic Syncing

Data is automatically synced via GitHub Actions:
- **Daily at ~6 AM CT** - Full sync of all data (only commits if data changed)
- **On push to main** - Rebuilds and deploys the site
- **Manual trigger** - Go to Actions → Sync Planning Center Data → Run workflow

## Project Structure

```
/
├── public/              # Static assets (images, favicon, etc.)
│   ├── hero/           # Hero slider images
│   ├── groups/         # Group images and leader photos
│   └── team/           # Team member photos
├── src/
│   ├── components/     # Reusable Astro components
│   │   ├── HeroSlider.astro
│   │   └── PageHero.astro
│   ├── data/           # JSON data files (auto-generated)
│   │   ├── events.json
│   │   ├── groups.json
│   │   ├── team.json
│   │   └── hero_images.json
│   ├── layouts/
│   │   └── Base.astro  # Main layout with header/footer
│   └── pages/          # Website pages (URL routes)
├── scripts/            # Ruby sync scripts
└── .github/workflows/  # GitHub Actions for CI/CD
```

## Pages

| Route | File | Description |
|-------|------|-------------|
| `/` | `index.astro` | Home page with hero slider |
| `/live` | `live.astro` | Live stream page |
| `/events` | `events.astro` | Upcoming events |
| `/groups` | `groups/index.astro` | Ministry groups |
| `/groups/[slug]` | `groups/[slug].astro` | Individual group pages |
| `/about` | `about.astro` | About the church |
| `/team` | `team.astro` | Staff and leadership |
| `/contact` | `contact.astro` | Contact information |
| `/directions` | `directions.astro` | Location and directions |
| `/give` | `give.astro` | Online giving |
| `/next-steps/*` | Various | New visitor resources |

## Making Changes

### Edit Page Content

1. Find the page file in `src/pages/`
2. Edit the HTML/Astro code
3. Run `npm run dev` to preview changes
4. Commit and push to deploy

### Update Navigation or Footer

Edit `src/layouts/Base.astro` - this file contains:
- Header and navigation menu
- Footer with service times, location, contact info
- Analytics tracking scripts

### Add a New Page

1. Create a new `.astro` file in `src/pages/`
2. Import the Base layout: `import Base from '../layouts/Base.astro';`
3. Wrap content in `<Base title="Page Title">...</Base>`
4. Add navigation link in `Base.astro` if needed

### Change Hero Images

Hero images are managed through Planning Center. To update:
1. Upload images to Planning Center
2. Run `ruby scripts/sync_hero_images.rb`
3. Images will appear in `public/hero/` and data in `src/data/hero_images.json`

## Development

```bash
# Start dev server (hot reload)
npm run dev

# Type checking
npm run astro check

# Build and preview production
npm run build && npm run preview
```

## Deployment

The site is hosted on GitHub Pages at [rol.church](https://rol.church).

Deployment happens automatically when changes are pushed to the `main` branch via GitHub Actions.

## Analytics

The site includes tracking for:
- Google Analytics 4
- Microsoft Clarity
- Meta Pixel (Facebook)

Events tracked include: page views, CTA clicks, form opens, scroll depth, time on page.

## Timezone

All event times are displayed in **Chicago time (Central Time)** regardless of visitor location.
