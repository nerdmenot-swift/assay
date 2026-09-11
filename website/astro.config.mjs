// The Assay documentation site — assay.nerdmenot.in
//
// Starlight owns `src/content/docs/**` and nothing else. The landing page is a plain
// Astro route with its own layout: a docs framework's default shell is the fastest way
// to look like every other project. Starlight is here for what it does better than a
// bespoke build — sidebar, search, keyboard nav, heading anchors, a11y — on the docs.
import { defineConfig } from 'astro/config'
import starlight from '@astrojs/starlight'

export default defineConfig({
  site: 'https://assay.nerdmenot.in',
  integrations: [
    starlight({
      title: 'Assay',
      description:
        'A decoder for Swift that tells you what went wrong. JSON, YAML, XML, TOML, ' +
        'property lists, HTTP bodies and database rows into ordinary structs — one set of ' +
        'rules, one kind of error, every error pointing at the byte, and faster than ' +
        'Codable while it does it.',
      logo: { src: './src/assets/icon.svg', alt: 'Assay', replacesTitle: false },
      favicon: '/icon.svg',
      customCss: ['./src/styles/theme.css'],
      // One code theme for both site modes: code reads as a terminal, and the error
      // renders on this site ARE terminal output.
      expressiveCode: {
        themes: ['github-dark'],
        styleOverrides: {
          borderRadius: '4px',
          borderColor: 'transparent',
          codeFontFamily: 'var(--assay-mono)',
        },
      },
      components: {
        Header: './src/components/Header.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/nerdmenot-swift/assay' },
      ],
      editLink: { baseUrl: 'https://github.com/nerdmenot-swift/assay/edit/main/website/' },
      lastUpdated: true,
      pagination: true,
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true } },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href:
              'https://fonts.googleapis.com/css2?' +
              'family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700&' +
              'family=Public+Sans:wght@400;500;600;700&' +
              'family=JetBrains+Mono:wght@400;500;600&display=swap',
          },
        },
        // Applied before first paint, so a collapsed table of contents does not flash
        // open on every navigation.
        {
          tag: 'script',
          content:
            "try{if(localStorage.getItem('assay:toc'))" +
            "document.documentElement.dataset.toc='collapsed'}catch(e){}",
        },
      ],
      sidebar: [
        {
          label: 'Start',
          items: [
            { slug: 'start/install' },
            { slug: 'start/first-schema' },
            { slug: 'start/from-codable' },
            { slug: 'start/cheatsheet' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { slug: 'guides/presence' },
            { slug: 'guides/keys' },
            { slug: 'guides/rules' },
            { slug: 'guides/checks' },
            { slug: 'guides/errors' },
            { slug: 'guides/dates' },
            { slug: 'guides/encoding' },
            { slug: 'guides/unions' },
            { slug: 'guides/advanced' },
          ],
        },
        // Formats get their own section rather than one page. Five parsers plus rows and
        // content negotiation is more than a guide holds, and "it reads more than JSON"
        // is the thing a reader is most likely to arrive not knowing.
        {
          label: 'Formats',
          items: [
            { slug: 'formats' },
            { slug: 'formats/json' },
            { slug: 'formats/yaml' },
            { slug: 'formats/xml' },
            { slug: 'formats/toml' },
            { slug: 'formats/plist' },
            { slug: 'formats/rows-and-columns' },
            { slug: 'formats/http' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { slug: 'reference/attributes' },
            { slug: 'reference/issue-codes' },
            { slug: 'reference/limits-and-security' },
            { slug: 'reference/performance' },
            { slug: 'reference/design-notes' },
          ],
        },
      ],
    }),
  ],
})
