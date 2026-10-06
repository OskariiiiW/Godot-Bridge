@tool
extends RefCounted
## texture_view: a texture, or part of it, enlarged without smoothing over a
## checkerboard, with a pixel grid and coordinates in the margins. A resource
## that holds a texture (an AtlasTexture, or any resource with a Texture2D
## property, such as an item) shows its whole sheet with the region it uses
## outlined. With sprites, the separate sprites in the shown part are found
## (connected non-transparent pixels), outlined, numbered and listed.

const BACKGROUND := Color(0.11, 0.11, 0.13)
const CHECKER: Array[Color] = [Color(0.2, 0.2, 0.24), Color(0.27, 0.27, 0.31)]
const CHECKER_SIZE := 8
const GRID_COLOR := Color(0.25, 0.85, 1.0, 0.4)
const HIGHLIGHT_COLOR := Color(1.0, 0.82, 0.1)
const SPRITE_COLOR := Color(0.35, 1.0, 0.45)
const LABEL_COLOR := Color(0.85, 0.85, 0.85)
const INDEX_BACKGROUND := Color(0, 0, 0, 0.75)
## Grid lines closer than this many output pixels are spread out (the grid doubles).
const MIN_GRID_SPACING := 6
## Sprite search limits: pixels scanned and sprites listed.
const SPRITE_SCAN_LIMIT := 1048576
const SPRITE_LIMIT := 200
## Pixels with less alpha than this count as transparent.
const ALPHA_THRESHOLD := 8
## Labels are drawn with a 3x5 pixel font, each font pixel this many pixels wide.
const FONT_SCALE := 2
const DIGITS := {
	"0": [7, 5, 5, 5, 7], "1": [2, 6, 2, 2, 7], "2": [7, 1, 7, 4, 7], "3": [7, 1, 7, 1, 7],
	"4": [5, 5, 7, 1, 1], "5": [7, 4, 7, 1, 7], "6": [7, 4, 7, 5, 7], "7": [7, 1, 1, 1, 1],
	"8": [7, 5, 7, 5, 7], "9": [7, 5, 7, 1, 7], ".": [0, 0, 0, 0, 2], "-": [0, 0, 7, 0, 0],
}

## Renders the view to out_path and describes it. rect is [x, y, w, h] in
## texture pixels; zoom 0 fits max_size; grid 0 draws no grid.
func render(path: String, property: String, rect: Variant, grid: int, zoom: float, max_size: int, sprites: bool, out_path: String) -> Dictionary:
	var source := _load_source(path, property)
	if source.has("error"):
		return source
	var image: Image = source.image
	var full := Rect2i(Vector2i.ZERO, image.get_size())
	var shown := full
	if rect is Array and rect.size() == 4:
		shown = Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])).intersection(full)
		if not shown.has_area():
			return {"error": "rect %s is outside the %dx%d texture." % [rect, full.size.x, full.size.y]}
	var crop := image.get_region(shown)

	var scale := zoom
	if scale <= 0.0:
		var fit := float(max_size if max_size > 0 else 1280) / maxi(shown.size.x, shown.size.y)
		scale = floorf(fit) if fit >= 1.0 else fit
	var out_size := Vector2i(maxi(1, roundi(shown.size.x * scale)), maxi(1, roundi(shown.size.y * scale)))
	var content := _checkerboard(out_size)
	var scaled := crop.duplicate()
	scaled.resize(out_size.x, out_size.y, Image.INTERPOLATE_NEAREST)
	content.blend_rect(scaled, Rect2i(Vector2i.ZERO, out_size), Vector2i.ZERO)

	var to_view := func(point: Vector2i) -> Vector2i: return Vector2i(((point - shown.position) as Vector2 * scale).round())
	var used_grid := grid
	if grid > 0:
		while used_grid * scale < MIN_GRID_SPACING:
			used_grid *= 2
		_draw_grid(content, shown, used_grid, to_view)

	var reply := {
		"texture": source.texture_path,
		"texture_size": [full.size.x, full.size.y],
		"shown": [shown.position.x, shown.position.y, shown.size.x, shown.size.y],
		"scale": scale,
		"grid": used_grid,
	}
	if source.has("properties"):
		reply.property = source.property
		reply.texture_properties = source.properties
	if source.has("region"):
		var region: Rect2i = source.region
		reply.region = [region.position.x, region.position.y, region.size.x, region.size.y]
		_outline(content, Rect2i(to_view.call(region.position), to_view.call(region.end) - to_view.call(region.position)), HIGHLIGHT_COLOR, 2)
	if sprites:
		var found := _find_sprites(crop, shown.position, used_grid if used_grid > 0 else 16)
		reply.merge(found)
		var index := 0
		for box in found.get("sprites", []):
			var at: Vector2i = to_view.call(Vector2i(box[0], box[1]))
			var size: Vector2i = to_view.call(Vector2i(box[0] + box[2], box[1] + box[3])) - at
			_outline(content, Rect2i(at, size), SPRITE_COLOR, 1)
			_label(content, str(index), at + Vector2i(1, 1), true)
			index += 1

	# Margins hold the coordinates of the labelled grid lines.
	var label_every := used_grid if used_grid > 0 else _round_step(48.0 / scale)
	while label_every * scale < _text_width(str(shown.end.x)) + 4 * FONT_SCALE:
		label_every *= 2
	var left := _text_width(str(shown.end.y)) + 3 * FONT_SCALE
	var top := 5 * FONT_SCALE + 3 * FONT_SCALE
	var view := Image.create(left + out_size.x, top + out_size.y, false, Image.FORMAT_RGBA8)
	view.fill(BACKGROUND)
	view.blit_rect(content, Rect2i(Vector2i.ZERO, out_size), Vector2i(left, top))
	for x in range(_first_multiple(shown.position.x, label_every), shown.end.x + 1, label_every):
		_label(view, str(x), Vector2i(left + to_view.call(Vector2i(x, shown.position.y)).x, FONT_SCALE))
	for y in range(_first_multiple(shown.position.y, label_every), shown.end.y + 1, label_every):
		var text := str(y)
		_label(view, text, Vector2i(left - FONT_SCALE * 2 - _text_width(text), top + to_view.call(Vector2i(shown.position.x, y)).y))

	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var error := view.save_png(out_path)
	if error != OK:
		return {"error": "Could not save the image: %s" % error_string(error)}
	reply.path = out_path
	reply.image_size = [view.get_width(), view.get_height()]
	reply.origin = [left, top]
	reply.note = "Texture pixel (x, y) is drawn at origin + (x - shown.x, y - shown.y) * scale in the image."
	return reply

## The image to show and, for a texture region, the region on it.
func _load_source(path: String, property: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		return {"error": "No resource at %s." % path}
	var resource := load(path)
	var result := {}
	var texture: Texture2D = resource as Texture2D
	if texture == null:
		var textures := {}
		for info in resource.get_property_list():
			if not info.usage & PROPERTY_USAGE_STORAGE:
				continue
			var value = resource.get(info.name)
			if value is Texture2D:
				textures[String(info.name)] = value
			elif value is Array:
				for i in value.size():
					if value[i] is Texture2D:
						textures["%s[%d]" % [info.name, i]] = value[i]
		if textures.is_empty():
			return {"error": "%s is a %s with no textures." % [path, resource.get_class()]}
		var chosen := property if not property.is_empty() else ("texture" if textures.has("texture") else String(textures.keys()[0]))
		if not textures.has(chosen):
			return {"error": "%s has no texture property %s; it has %s." % [path, chosen, ", ".join(PackedStringArray(textures.keys()))]}
		texture = textures[chosen]
		result.property = chosen
		result.properties = textures.keys()
	# A region of a sheet: show the sheet, with the region outlined.
	if texture is AtlasTexture and texture.atlas != null:
		var region := Rect2i(texture.region)
		var sheet: Texture2D = texture.atlas
		while sheet is AtlasTexture and sheet.atlas != null:
			region.position += Vector2i(sheet.region.position)
			sheet = sheet.atlas
		result.region = region
		texture = sheet
	var image := texture.get_image()
	if image == null:
		return {"error": "The texture in %s has no image data to show." % path}
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	result.image = image
	result.texture_path = texture.resource_path if not texture.resource_path.is_empty() else path
	return result

func _checkerboard(size: Vector2i) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(CHECKER[0])
	for y in range(0, size.y, CHECKER_SIZE):
		for x in range((y / CHECKER_SIZE) % 2 * CHECKER_SIZE, size.x, CHECKER_SIZE * 2):
			image.fill_rect(Rect2i(x, y, CHECKER_SIZE, CHECKER_SIZE), CHECKER[1])
	return image

## Lines are `width` image pixels wide, centred on the grid position.
func _draw_grid(image: Image, shown: Rect2i, grid: int, to_view: Callable, width := 1, color := GRID_COLOR) -> void:
	var size := image.get_size()
	var vertical := Image.create(width, size.y, false, Image.FORMAT_RGBA8)
	vertical.fill(color)
	var horizontal := Image.create(size.x, width, false, Image.FORMAT_RGBA8)
	horizontal.fill(color)
	var half := width / 2
	for x in range(_first_multiple(shown.position.x, grid), shown.end.x + 1, grid):
		var at: int = clampi(to_view.call(Vector2i(x, shown.position.y)).x - half, 0, size.x - width)
		image.blend_rect(vertical, Rect2i(0, 0, width, size.y), Vector2i(at, 0))
	for y in range(_first_multiple(shown.position.y, grid), shown.end.y + 1, grid):
		var at: int = clampi(to_view.call(Vector2i(shown.position.x, y)).y - half, 0, size.y - width)
		image.blend_rect(horizontal, Rect2i(0, 0, size.x, width), Vector2i(0, at))

func _outline(image: Image, rect: Rect2i, color: Color, width: int) -> void:
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if not rect.has_area():
		return
	width = mini(width, mini(rect.size.x, rect.size.y))
	image.fill_rect(Rect2i(rect.position, Vector2i(rect.size.x, width)), color)
	image.fill_rect(Rect2i(rect.position.x, rect.end.y - width, rect.size.x, width), color)
	image.fill_rect(Rect2i(rect.position, Vector2i(width, rect.size.y)), color)
	image.fill_rect(Rect2i(rect.end.x - width, rect.position.y, width, rect.size.y), color)

## Sprites: groups of touching (including diagonally) non-transparent pixels,
## in reading order by grid rows, as [x, y, w, h] in texture pixels.
func _find_sprites(crop: Image, offset: Vector2i, row_height: int) -> Dictionary:
	var size := crop.get_size()
	if size.x * size.y > SPRITE_SCAN_LIMIT:
		return {"sprites_note": "The shown area is too large to search for sprites (over %d pixels); pass a smaller rect." % SPRITE_SCAN_LIMIT}
	var data := crop.get_data()
	var seen := PackedByteArray()
	seen.resize(size.x * size.y)
	var boxes := []
	var stack := PackedInt32Array()
	for start in size.x * size.y:
		if seen[start] or data[start * 4 + 3] < ALPHA_THRESHOLD:
			continue
		seen[start] = 1
		stack.append(start)
		var low := Vector2i(start % size.x, start / size.x)
		var high := low
		var count := 0
		while not stack.is_empty():
			var at := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			count += 1
			var x := at % size.x
			var y := at / size.x
			low = Vector2i(mini(low.x, x), mini(low.y, y))
			high = Vector2i(maxi(high.x, x), maxi(high.y, y))
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= size.x or ny >= size.y:
						continue
					var next := ny * size.x + nx
					if not seen[next] and data[next * 4 + 3] >= ALPHA_THRESHOLD:
						seen[next] = 1
						stack.append(next)
		# Lone pixels are specks, not sprites.
		if count > 1:
			boxes.append([low.x + offset.x, low.y + offset.y, high.x - low.x + 1, high.y - low.y + 1])
	boxes.sort_custom(func(a: Array, b: Array) -> bool:
		var row_a: int = a[1] / row_height
		var row_b: int = b[1] / row_height
		return row_a < row_b if row_a != row_b else a[0] < b[0])
	var reply := {"sprites": boxes.slice(0, SPRITE_LIMIT)}
	if boxes.size() > SPRITE_LIMIT:
		reply.sprites_note = "%d sprites found; the first %d are listed. Pass a smaller rect to see the rest." % [boxes.size(), SPRITE_LIMIT]
	return reply

## Draws digits with the 3x5 font; with backing, over a dark box so it reads on
## any colour. Also used for the time labels of animation_frames. font_scale
## is the size of a font pixel (FONT_SCALE by default).
func _label(image: Image, text: String, at: Vector2i, backing := false, font_scale := FONT_SCALE) -> void:
	if backing:
		var box := Rect2i(at - Vector2i(1, 1), Vector2i(_text_width(text, font_scale) + 2, 5 * font_scale + 2)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		if box.has_area():
			var shade := Image.create(box.size.x, box.size.y, false, Image.FORMAT_RGBA8)
			shade.fill(INDEX_BACKGROUND)
			image.blend_rect(shade, Rect2i(Vector2i.ZERO, box.size), box.position)
	var bounds := Rect2i(Vector2i.ZERO, image.get_size())
	for i in text.length():
		var rows: Array = DIGITS.get(text[i], [])
		for row in rows.size():
			for column in 3:
				if rows[row] & (4 >> column):
					var pixel := Rect2i(at + Vector2i((i * 4 + column) * font_scale, row * font_scale), Vector2i(font_scale, font_scale)).intersection(bounds)
					if pixel.has_area():
						image.fill_rect(pixel, LABEL_COLOR)

func _text_width(text: String, font_scale := FONT_SCALE) -> int:
	return maxi(0, text.length() * 4 - 1) * font_scale

func _first_multiple(from: int, step: int) -> int:
	return ceili(float(from) / step) * step

## A round label spacing (1, 2, 5, 10, 20, ...) of at least `at_least` pixels.
func _round_step(at_least: float) -> int:
	var step := 1
	while true:
		for factor in [1, 2, 5]:
			if step * factor >= at_least:
				return step * factor
		step *= 10
	return step
