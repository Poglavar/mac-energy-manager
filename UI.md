# Call graph viewer UI

`web/graph.html` is the viewer document and `web/graph.css` owns presentation. The supported local server is `bin/energy-graph serve`; it serves `/` and the same-origin `/graph.css` asset, while process data and stop behavior remain on their existing endpoints.

CSS variables describe interface roles such as page, text, surface, border, and emphasis. The fixed CPU ramp is a separate data encoding bound through `--process-bin-*` roles. JavaScript may set only documented layout custom properties for data-driven geometry: `--node-x`, `--node-y`, `--via-x`, `--via-y`, `--via-width`, `--stage-width`, `--stage-height`, `--tip-x`, and `--tip-y`. SVG path geometry stays in SVG attributes.
