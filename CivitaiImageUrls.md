# Image & Media URLs

Civitai serves images and videos through Cloudflare's image transformation service. The API returns a UUID in the
`url` field of image objects — this UUID must be combined with a base URL, transformation parameters, and a filename
to construct a usable media URL.

Source: `civitai/src/client-utils/cf-images-utils.ts`

## URL Pattern

```
https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/{params}/{name}
```

| Component | Description                                                                 |
|-----------|-----------------------------------------------------------------------------|
| uuid      | The value from the `url` field in API responses (e.g., image.getInfinite)   |
| params    | Comma-separated `key=value` transformation parameters (see below)           |
| name      | `{id}.{extension}` where id is the image ID and extension is based on type  |

### Extensions

| Media Type | Extension |
|------------|-----------|
| image      | `.jpeg`   |
| video      | `.mp4`    |
| audio      | `.mp3`    |

## Transformation Parameters

Based on [Cloudflare Flexible Variants](https://developers.cloudflare.com/images/cloudflare-images/transform/flexible-variants/).

| Parameter  | Type    | Range/Values                                            | Description                                                    |
|------------|---------|---------------------------------------------------------|----------------------------------------------------------------|
| width      | number  | 1–1800                                                  | Output width in pixels. Clamped to max 1800                    |
| height     | number  | 1–1000                                                  | Output height in pixels. Clamped to max 1000                   |
| fit        | string  | `scale-down`, `contain`, `cover`, `crop`, `pad`         | How the image is resized to fit width/height                   |
| anim       | boolean | `true`, `false`                                         | Set `false` to get a static frame from GIFs/videos             |
| transcode  | boolean | `true`, `false`                                         | Set `true` to enable video transcoding (required for playback) |
| quality    | number  | 0–100                                                   | JPEG/WebP quality                                              |
| blur       | number  | 0–250                                                   | Gaussian blur radius                                           |
| gravity    | string  | `auto`, `side`, `left`, `right`, `top`, `bottom`        | Crop anchor point (used with `fit=crop`)                       |
| metadata   | string  | `keep`, `copyright`, `none`                             | Which EXIF metadata to preserve                                |
| background | string  | CSS color                                               | Background color for `fit=pad`                                 |
| gamma      | number  |                                                         | Gamma correction                                               |
| optimized  | boolean | `true`, `false`                                         | Enable format optimization (e.g., WebP/AVIF)                  |
| original   | boolean | `true`, `false`                                         | Serve original file (ignores width/height)                     |
| skip       | number  |                                                         | Frame skip for video thumbnail extraction                      |

### Default Behavior

- If neither `width`, `height`, nor `original` is specified, `original=true` is assumed
- If `original=true`, width and height are ignored
- Only parameters with defined values are included in the URL (undefined params are omitted)
- The `anim` parameter uses inverted logic: it is only included when `false` (to disable animation)
- The `transcode` parameter is only included when `true`

## Common URL Patterns

### Image thumbnail (static, optimized)
```
https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/anim=false,width=450,optimized=true/{id}.jpeg
```

### Video playback
```
https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/transcode=true,width=450,optimized=true/{id}.mp4
```

### Video thumbnail (static frame)
```
https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/transcode=true,anim=false,skip=4,width=450/{id}.jpeg
```

### Original full-size image
```
https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/original=true/{id}.jpeg
```

## Notes

- The base URL path segment `xG1nkqKTMzGDvpLrqFT7WA` is the Cloudflare account hash
- If the `url` field already starts with `http` or `blob`, it should be used as-is (no transformation)
- The `name` component has `%` characters stripped (URL encoding escape character)
- For video content displayed as an image (e.g., thumbnails in grids), set `transcode=true` and `anim=false`
  to extract a static frame
- The `optimized` flag is automatically enabled by the Civitai web client when width ≤ 450, or when the user
  has set their image format preference to "optimized"
