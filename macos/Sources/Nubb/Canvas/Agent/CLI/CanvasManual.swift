/// The text `nubb +canvas help` prints. Written for people and AI agents:
/// one read should be enough to draw, check, and update a diagram.
enum CanvasManual {
    static let text = """
    nubb +canvas: draw and update Excalidraw diagrams from the shell.

    Drawings are plain .excalidraw files that open in Nubb, excalidraw.com and
    Obsidian. You describe nodes (text, boxes, code, frames, arrows) in JSON
    and the tool lays them out with the real fonts: no coordinates to guess,
    no text widths to estimate. Every node keeps the id you give it, so you
    can change it later. When the person you work with moves or edits things
    by hand, your next change keeps their edits.

    USAGE
      nubb +canvas <command> <file.excalidraw> [args] [options]

    HOW TO MAKE A DIAGRAM
      1. Write a spec (see SPEC below, and `nubb +canvas help spec`):
           {"nodes": [{"frame": "1. Overview", "id": "p1", "children": [
              {"text": "How a request flows", "size": "l"},
              "Requests enter at the edge and fan out to shards.",
              {"row": [{"box": "Edge", "id": "edge"}, {"box": "Shard", "id": "shard"}]},
              {"arrow": "routes", "from": "edge", "to": "shard"}]}]}
      2. nubb +canvas apply notes.excalidraw spec.json
      3. Open notes.excalidraw in Nubb to see it.
      4. Change things by id: nubb +canvas set notes.excalidraw edge text="CDN edge"
         An open canvas updates in place without moving its camera.
      5. Before changing more, see what they did: nubb +canvas changes notes.excalidraw
         apply, set, move and delete keep their moves and edits.

    WRITE
      apply <file> <spec>      Add or replace nodes from a spec: a .json file,
                               - for stdin, or inline JSON. Creates the file.
                               Applying a node with an id that exists replaces
                               it in place; other nodes stay as they are.
          --dry-run            Report what would change without writing.
          --json               Print the report as JSON: created, updated and
                               deleted ids, every node's box, and user changes.
          --quiet              Don't list the top-level nodes.
      set <file> <id> key=value...
                               Change a node or element by id: text=..., label=,
                               name= (the hover name; a frame's title), code=,
                               size=, color=, fill=,
                               width=, font=, or any style or Excalidraw field.
                               Text values are taken as is; use \\n for a new
                               line. A JSON object works too: set f id '{"size": 28}'.
      move <file> <id> <dx> <dy>
                               Move a node, with everything in it, by dx, dy.
      delete <file> <id>...    Delete nodes or elements, with what they contain.
      reset <file> <id>...|--all
                               Forget the hand edits to these nodes, so they
                               show the spec again. Brings back parts the
                               person deleted.
      new <file> [--force]     Create an empty drawing.

    READ
      info <file> [--json]     Element counts, bounds, frames, and top-level nodes.
      frames <file> [--json]   Frames with ids, names, boxes and element counts.
      list <file>              One line per element: id, type, box, text, frame.
          --frame <name>       Only the elements of one frame.
          --type text,arrow    Only these element types.
          --near x,y,w,h       Only elements touching this area.
          --ids                Print only ids.   --json   As JSON.
      get <file> <id>...       The element's Excalidraw JSON, or for a layout
                               node its spec, box and elements.
      spec <file> [<id>...]    The specs apply stored, with the ids it filled in.
                               Edit and apply them again to change a node.
      measure "<text>"         The size text takes, measured with the real font.
          --font hand|normal|code|comic   --size 20|s|m|l|xl
          --width <px>         Wrap to this width and print the lines.
          --spec <json>        Lay out spec nodes without drawing them, and
                               print their boxes. --in <file> uses its styles.
      changes <file>           What the person changed by hand since your last
                               write: moved, edited, added, deleted, by id.
          --ack                Mark them as seen (apply does this too).
          --json               With old and new values of each field.

    SPEC
      A spec is {"nodes": [...]}, an array of nodes, or one node. Each node
      has one kind key whose value is its content:
        {"text": "Words"}              a paragraph; a bare "string" is one too
        {"box": "Label"}               a rounded box with a centered label
        {"ellipse": "..."}  {"diamond": "..."}
        {"box": [nodes...]}            a card: a box around a stack of nodes
        {"code": "let x = 1"}          monospace text on a light panel
        {"frame": "Name", "children": [nodes...]}
                                       a named panel that grows to fit
        {"stack": [...]}  {"row": [...]}  {"grid": [...], "columns": 3}
        {"arrow": "label", "from": "id", "to": "id"}
        {"line": "", "from": [x, y], "to": "id"}
        {"type": "rectangle", ...}     a raw Excalidraw element
      Common fields: "id", "at": [x, y] (top-level or inside a parent),
      "name" (shown on hover), "style": "name", color, fill, size, font,
      and layout fields such as width, gap, padding, align. Run
      `nubb +canvas help spec` for all of them, with colors, fonts, sizes,
      and examples.

    HOVER NAMES
      Give a box, shape, text, code block or arrow a "name" and the viewer
      shows it, at a readable size, when the pointer rests on it. Use it to
      keep labels short ("API") and say more on hover ("Go service that
      validates requests and writes to Postgres"), or to make small or
      zoomed-out parts readable. Names are saved in the element's
      customData, so Excalidraw keeps them. The person can add or edit one
      with right-click > Name.

    IDS
      Give top-level nodes and anything you'll change later an "id". Children
      without one get their parent's id and position: p1.0, p1.1. Parts of a
      node are <id>:<part>: b1:label, c1:code, p1:bg. Use the node id in
      set, move, and delete.

    HAND EDITS
      The tool remembers what it wrote. Whatever the person changes by hand
      (moves, resizes, text, colors, deletions) is kept on top of later
      applies: moving a frame moves everything in it, and a node you change
      again keeps their move. When you change the same field they did, yours
      wins. `changes` lists their edits, `reset` drops them.

    OUTPUT
      Results go to stdout, errors to stderr. Exit codes: 0 success,
      1 failure, 2 usage or spec error. Spec errors
      list every problem with its path, like nodes[0].children[2].fill.
      State is kept in ~/Library/Application Support/com.evancdev.nubb/CanvasAgent
      (NUBB_CANVAS_STATE_DIR overrides it), never in the drawing.

    EXAMPLES
      nubb +canvas apply notes.excalidraw - <<'EOF'
      {"nodes": [{"frame": "2. Retries", "id": "p2", "children": [
        {"text": "Retries back off", "size": "l"},
        {"code": "delay = base * 2 ** attempt", "id": "p2code"}]}]}
      EOF
      nubb +canvas set notes.excalidraw p2code code="delay = min(cap, base * 2 ** n)"
      nubb +canvas measure "Requests fan out to shards" --size 20 --width 240

    """

    static let spec = """
    nubb +canvas help spec: everything a spec can say.

    TOP LEVEL
      {"nodes": [...], "styles": {...}, "defaults": {...},
       "set": {"id": {fields}}, "move": {"id": [dx, dy]}, "delete": ["id", ...]}
      Every key is optional. Styles and defaults are remembered by the
      drawing, so later applies can use them.

    NODES
      text      {"text": "A paragraph"} or just "A paragraph". Arrays of lines
                work too. Wraps to the space its parent gives it, or at 32
                times its font size (640 px at size 20) when nothing sets a
                width. width: <px> wraps to that width. maxWidth: <px>.
                wrap: false keeps it on one line.
      box       {"box": "Label"}: a box sized to its label, centered.
                {"box": [nodes]} or {"box": null, "children": [nodes]}: a card,
                a box around a stack of nodes. padding, gap, align.
                width, height, minWidth, minHeight, maxWidth.
      ellipse, diamond: like box.
      code      {"code": "lines\\nof code"}: monospace on a light panel.
                width, padding. wrap: true wraps long lines.
      frame     {"frame": "Name", "children": [...]}: a named panel that grows
                to fit. width, height, minHeight, padding (default 28), gap.
                A fill gives the panel a background. Frames can't nest.
                Nubb doesn't draw the name (Excalidraw shows it above the
                frame); use it to find the frame, and put a title inside.
      stack     {"stack": [...]}: one above the other. gap (16), align:
                start|center|end|stretch, padding, width.
      row       {"row": [...]}: side by side. gap (24), align (start). Text
                and code in a row share the width left by the other nodes.
                width: "fill" makes any node share it too.
      grid      {"grid": [...], "columns": 3}: equal columns. gap, rowGap,
                columnWidth, align (stretch: cells in a row match heights).
                A row or grid of frames makes panels of matching size.
      arrow     {"arrow": "label", "from": "id" | [x, y], "to": "id" | [x, y]}
                Ends attach to the shapes they name and follow them when they
                move. Any node id works, including frames, stacks and cards.
                route: "elbow" for right angles; fromSide/toSide:
                left|right|top|bottom pick the sides (and imply elbow).
                startHead/endHead: arrow, bar, dot, triangle, diamond, none, ...
      line      like arrow, without arrowheads by default.
      raw       {"type": "rectangle", "x": 0, ...}: an Excalidraw element as is.

    PLACEMENT
      Top-level nodes go below what's drawn, or at "at": [x, y]. Inside a
      layout, "at": [x, y] places a child relative to its parent's corner
      instead of in the flow. "shift": [dx, dy] nudges a node after layout.

    STYLE FIELDS (on any node, in "styles", or in "defaults")
      color      stroke and text: #rrggbb, black, white, transparent, or a
                 palette color: gray red pink grape violet blue cyan teal
                 green yellow orange bronze. Add .0 to .4 for a shade
                 (blue.0 lightest). Plain names pick Excalidraw's defaults:
                 the dark shade for color, the light one for fill.
      fill       background, same names. fillStyle: solid|hachure|cross-hatch|zigzag.
      stroke     solid|dashed|dotted.    strokeWidth: thin|bold|extra or a number.
      rough      architect|artist|cartoonist or 0-4 (0 is clean lines).
      round      true|false (rounded corners).   opacity: 0-100.
      font       hand (Excalifont), normal (Nunito), code (Cascadia), comic,
                 virgil, helvetica, lilita, liberation, or a font number.
      size       s|m|l|xl (16, 20, 28, 36) or a number.
      align      text alignment left|center|right. On layouts, frames and
                 cards it aligns the children instead. valign: top|middle|bottom.

      "styles": {"callout": {"fill": "yellow", "stroke": "dashed"}}
      {"box": "Remember this", "style": "callout"}
      "defaults": {"text": {"size": 18}, "frame": {"fill": "gray.0"}}

    OTHER FIELDS
      id         letters, digits, _ - . (see IDS in `nubb +canvas help`)
      group      true makes Excalidraw select the node's elements together.
                 Cards and code blocks are grouped unless false.
      locked     true makes it unselectable in the viewer.
      link       a URL for the element.
      name       text shown on hover: {"box": "API", "name": "Go service,
                 validates and writes to Postgres"}. Not on frames (their
                 title is their name) or stack/row/grid (not drawn).

    EXAMPLE: one panel of an explainer
      {"defaults": {"frame": {"fill": "gray.0"}},
       "nodes": [{"frame": "3. Write path", "id": "p3", "width": 720, "children": [
         {"text": "Write path", "size": "xl", "font": "hand"},
         "Writes go to the leader, which replicates to two followers before acking.",
         {"row": [
           {"box": "Client", "id": "client", "fill": "blue"},
           {"box": "Leader", "id": "leader", "fill": "green"},
           {"stack": [{"box": "Follower A", "id": "fa"}, {"box": "Follower B", "id": "fb"}]}
         ], "gap": 80, "align": "center"},
         {"arrow": "write", "from": "client", "to": "leader"},
         {"arrow": "", "from": "leader", "to": "fa"},
         {"arrow": "", "from": "leader", "to": "fb"},
         {"code": "await leader.write(key, value) // resolves after 2 acks"}]}]}

    """
}
