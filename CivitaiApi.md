# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

The source code for the APIs (and the Civitai website in general) is available as a peer of this project, in the
directory called "civitai". You can look at the source code there to understand better how the APIs work.

# Authentication

API requests can be authenticated using an API key passed as a Bearer token:

```
Authorization: Bearer {api_key}
```

API keys have scopes that control what they can do:

| Scope    | Description                          |
|----------|--------------------------------------|
| Read     | Read data (images, posts, etc.)      |
| Write    | Write data (create posts, react)     |
| Generate | Use image generation features        |

Public endpoints (marked "public" in this doc) do not require authentication. Protected endpoints require a valid
API key. Some endpoints are further restricted to verified users, moderators, or resource owners.

Additional session headers used by the web client:
- `x-session-refresh` — session refresh header
- `civ-session-refresh` — session refresh cookie

# Rate Limiting

Certain endpoints have rate limits that vary based on user reputation score.

### Reactions (`reaction.toggle`)

| Window  | Standard | Reputation ≥ 1000 |
|---------|----------|--------------------|
| 1 min   | 60       | 100                |
| 10 min  | 300      | 500                |
| 1 hour  | 1,000    | 1,500              |
| 1 day   | 5,000    | 8,000              |

### Comments (`comment.upsert`)

| Window  | Standard | Reputation ≥ 1000 |
|---------|----------|--------------------|
| 1 hour  | 10       | 60                 |
| 1 day   | 40       | 480                |

# Pagination Patterns

The API uses two pagination styles:

### Cursor-based (infinite scroll)

Most `getInfinite` endpoints use cursor-based pagination. The response includes a `nextCursor` value to pass as
the `cursor` parameter in the next request.

Cursor formats vary by endpoint:
- **ISO date string** — e.g., `"2024-03-22T10:52:00.000Z"` (used by image.getInfinite)
- **Pipe-delimited** — e.g., `"value|id"` (used by post.getInfinite)

### Offset-based

Some endpoints use traditional `limit` + `page` parameters for pagination.

# Enums & Constants

## Content Levels (browsingLevel)

Content filtering uses bit flags that can be combined with bitwise OR.

| Level   | Value | Label   | Description                                    |
|---------|-------|---------|------------------------------------------------|
| PG      | 1     | PG      | Safe for work, fully clothed                   |
| PG13    | 2     | PG-13   | Revealing clothing, light suggestive content    |
| R       | 4     | R       | Partial nudity, adult themes                   |
| X       | 8     | X       | Graphic nudity, genitalia                      |
| XXX     | 16    | XXX     | Sexual acts, explicit content                  |
| Blocked | 32    | Blocked | Violates terms of service                      |

### Common Combinations

| Name                     | Value | Levels included       |
|--------------------------|-------|-----------------------|
| publicBrowsingLevelsFlag | 1     | PG only               |
| sfwBrowsingLevelsFlag    | 3     | PG + PG13             |
| nsfwBrowsingLevelsFlag   | 60    | R + X + XXX + Blocked |
| allBrowsingLevelsFlag    | 31    | PG through XXX        |

### Content Category Tag IDs

These tag IDs can be used with `excludedTagIds` to filter content categories:

| Category | Tag IDs              |
|----------|----------------------|
| Anime    | 4 (anime), 413 (manga) |
| Furry    | 5139 (anthro), 5140 (furry) |
| Gore     | 1282 (gore), 789 (body horror) |
| Political| 2470 (political)     |

## Reactions

| Value   | Emoji |
|---------|-------|
| Like    | 👍    |
| Dislike | 👎    |
| Heart   | ❤️    |
| Laugh   | 😂    |
| Cry     | 😢    |

## Time Periods (MetricTimeframe)

Used in `period` parameters: `"Day"`, `"Week"`, `"Month"`, `"Year"`, `"AllTime"`

## Media Types

Used in `types` filter parameters: `"image"`, `"video"`, `"audio"`

## Model Types

`"Checkpoint"`, `"TextualInversion"`, `"Hypernetwork"`, `"AestheticGradient"`, `"LORA"`, `"LoCon"`, `"DoRA"`,
`"Controlnet"`, `"Upscaler"`, `"MotionModule"`, `"VAE"`, `"Poses"`, `"Wildcards"`, `"Workflows"`, `"Detection"`,
`"Other"`

## Collection Types

Used in `type` parameters: `"Model"`, `"Article"`, `"Post"`, `"Image"`

## Collection Modes

`"Contest"`, `"Bookmark"`

## Image Generation Process

`"txt2img"`, `"txt2imgHiRes"`, `"img2img"`, `"inpainting"`

## Sort Options by Entity

### Images (ImageSort)
`"Most Reactions"`, `"Most Comments"`, `"Most Collected"`, `"Newest"`, `"Oldest"`, `"Random"`

### Posts (PostSort)
`"Most Reactions"`, `"Most Comments"`, `"Most Collected"`, `"Newest"`

### Models (ModelSort)
`"Highest Rated"`, `"Most Downloaded"`, `"Most Liked"`, `"Most Discussed"`, `"Most Collected"`, `"Image Count"`,
`"Newest"`, `"Oldest"`

### Collections (CollectionSort)
`"Most Contributors"`, `"Newest"`

# Endpoint Reference

# image.getInfinite

## Overview

Retrieve paginated images from Civitai with powerful filtering and sorting options. Perfect for building
galleries, feeds, or browsing interfaces.

## Endpoint

`POST /api/trpc/image.getInfinite`

## Request Parameters

### Core Parameters

| Parameter     | Type     | Default          | Description                                                                |
|---------------|----------|------------------|----------------------------------------------------------------------------|
| limit         | number   | 50               | Images per page (0-200)                                                    |
| cursor        | string   | -                | For pagination (use nextCursor from previous response, ISO date format)    |
| sort          | string   | "Most Reactions" | Sort order (see options below)                                             |
| period        | string   | "AllTime"        | Time range: "Day", "Week", "Month", "Year", "AllTime"                      |
| periodMode    | string   | "published"      | Whether to filter by "stats" or "published" timestamp                      |
| browsingLevel | number   | all levels       | Content level bit flags: PG=1, PG13=2, R=4, X=8, XXX=16 (combine with OR)  |
| useIndex      | boolean  | false            | Whether to use the Meilisearch index for faster lookups                    |

### Filtering Parameters

| Parameter          | Type     | Description                                      |
|--------------------|----------|--------------------------------------------------|
| types              | string[] | Media types: "image", "video", "audio"           |
| postId             | number   | Filter to a specific post                        |
| postIds            | number[] | Filter to multiple posts                         |
| collectionId       | number   | Filter to a specific collection                  |
| modelId            | number   | Filter by model ID                               |
| modelVersionId     | number   | Filter by model version ID                       |
| userId             | number   | Filter by user ID                                |
| username           | string   | Filter by username                               |
| followed           | boolean  | Show only from followed users                    |
| tags               | number[] | Filter by tag IDs                                |
| excludedTagIds     | number[] | Exclude specific tag IDs                         |
| excludedUserIds    | number[] | Exclude specific user IDs                        |
| tools              | number[] | Filter by tool IDs                               |
| techniques         | number[] | Filter by technique IDs                          |
| baseModels         | string[] | Filter by base model identifiers                 |
| reactions          | string[] | Filter by reaction types (Like, Heart, etc.)     |
| generation         | string[] | Filter by generation process type                |
| ids                | number[] | Fetch specific image IDs                         |
| remixOfId          | number   | Filter to remixes of a specific image            |
| remixesOnly        | boolean  | Show only remixes                                |
| nonRemixesOnly     | boolean  | Exclude remixes                                  |
| hidden             | boolean  | Show only hidden images                          |
| fromPlatform       | boolean  | Filter by platform origin                        |

### Include Options

| Parameter   | Type     | Default       | Description                                      |
|-------------|----------|---------------|--------------------------------------------------|
| include     | string[] | ["cosmetics"] | Data to include: "tags", "count", "cosmetics", "meta", "tagIds", "profilePictures" |
| withMeta    | boolean  | false         | Shorthand to include generation metadata         |
| withTags    | boolean  | false         | Shorthand to include tags                        |

### Sorting Options

- "Most Reactions" - Most liked/hearted (default)
- "Most Comments" - Most discussed
- "Most Collected" - Most saved to collections
- "Newest" - Latest uploads first
- "Oldest" - Oldest uploads first
- "Random" - Random order

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ],
        "nextCursor": "..."
      }
    }
  }
}
```

### Image Properties (in items)

#### Core Properties

| Field          | Type    | Description                              |
| -------------- | ------- | ---------------------------------------- |
| id             | number  | Unique image identifier                  |
| url            | string  | Direct image URL                         |
| hash           | string  | Image hash (nullable)                    |
| width          | number  | Image width (nullable)                   |
| height         | number  | Image height (nullable)                  |
| nsfwLevel      | number  | Content level                            |
| type           | string  | Content type ("image", "video")          |
| postId         | number  | The post that the image belongs to       |
| index          | number  | Position index within post (nullable)    |
| modelVersionId | number  | Associated model version ID (nullable)   |
| createdAt      | string  | Creation timestamp                       |
| sortAt         | string  | Sort timestamp                           |
| publishedAt    | string  | Published timestamp (nullable)           |
| thumbnailUrl   | string  | Thumbnail URL (nullable)                 |
| user           | object  | Creator info (see below)                 |
| stats          | object  | Statistics (see below)                   |
| reactions      | array   | User reactions on this image             |
| cosmetic       | object  | User cosmetic info (nullable)            |
| tags           | array   | Tag objects (if requested via include)   |
| tagIds         | array   | Tag IDs (always included by handler)     |

#### Creator Info (user property object)

| Field    | Type   | Description         |
| -------- | ------ | ------------------- |
| id       | number | User ID             |
| username | string | Display name        |
| image    | string | Profile picture URL |

#### Engagement (stats property object)

| Field                    | Type   | Description                |
| ------------------------ | ------ | -------------------------- |
| likeCountAllTime         | number | Total likes                |
| laughCountAllTime        | number | Total laughs               |
| heartCountAllTime        | number | Total hearts               |
| cryCountAllTime          | number | Total cries                |
| dislikeCountAllTime      | number | Total dislikes             |
| commentCountAllTime      | number | Total comments             |
| collectedCountAllTime    | number | Total collections saved to |
| tippedAmountCountAllTime | number | Total tips                 |
| viewCountAllTime         | number | Total view count           |

# image.getGenerationData

## Overview

Retrieves the generation information for an image or video, including prompts, model resources, tools, and techniques used.

## Endpoint

`POST /api/trpc/image.getGenerationData`

## Request Parameters

| Parameter | Type   | Description                              |
|-----------|--------|------------------------------------------|
| id        | number | ID of the image generation data to fetch |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field      | Type    | Description                                                      |
|------------|---------|------------------------------------------------------------------|
| type       | string  | Content type ("image", "video")                                  |
| onSite     | boolean | Whether image was generated on Civitai                           |
| process    | string  | Generation process (e.g., "txt2img", "img2img", "comfy")         |
| meta       | object  | Generation parameters (see below). Null if creator hid metadata  |
| resources  | array   | List of models used in generation (see below)                    |
| tools      | array   | List of tools used (see below)                                   |
| techniques | array   | List of techniques used (see below)                              |
| external   | object  | External service metadata (see below, nullable)                  |
| canRemix   | boolean | Whether image can be remixed (has visible prompt)                |
| remixOfId  | number  | ID of the source image if this is a remix (nullable)             |

#### Meta properties

| Field          | Type   | Description                                          |
|----------------|--------|------------------------------------------------------|
| prompt         | string | Primary text prompt used for generation              |
| negativePrompt | string | Negative prompt to exclude unwanted elements         |
| cfgScale       | number | Classifier-Free Guidance scale (typically 1-30)      |
| steps          | number | Number of denoising steps (typically 20-150)         |
| sampler        | string | Sampling method (e.g., "DPM++ 2M Karras", "Euler a") |
| seed           | number | Random seed for reproducible generation              |
| clipSkip       | number | CLIP skip layers (typically 1-2)                     |
| baseModel      | string | Base model identifier (e.g., "SD 1.5", "SDXL")       |
| comfy          | object | ComfyUI workflow data (if applicable)                |

#### Resource properties

| Field           | Type   | Description                                                    |
|-----------------|--------|----------------------------------------------------------------|
| imageId         | number | The image ID this resource is associated with                  |
| modelId         | number | The model ID of the model used                                 |
| modelName       | string | The name of the model                                          |
| modelType       | string | The type of the model ("Checkpoint", "LORA", "DoRA", etc.)     |
| modelVersionId  | number | The version ID of the model used                               |
| versionId       | number | Alias for modelVersionId                                       |
| versionName     | string | The name of the model version                                  |
| baseModel       | string | The base model this resource is built on                       |
| strength        | number | The strength (0-1 range for LORA/DoRA/LoCon/TI, nullable)      |

#### Tool properties

| Field    | Type   | Description                    |
|----------|--------|--------------------------------|
| id       | number | Tool ID                        |
| name     | string | Tool name                      |
| icon     | string | Tool icon URL                  |
| domain   | string | Tool website domain            |
| priority | number | Display priority               |
| notes    | string | User notes about the tool      |

#### Technique properties

| Field | Type   | Description                       |
|-------|--------|-----------------------------------|
| id    | number | Technique ID                      |
| name  | string | Technique name                    |
| notes | string | User notes about the technique    |

#### External properties (when present)

| Field        | Type   | Description                              |
|--------------|--------|------------------------------------------|
| source       | object | External service info (name, homepage)   |
| details      | object | Custom key-value metadata from service   |
| createUrl    | string | URL used to create the media             |
| referenceUrl | string | Source URL of the media                  |

# post.getInfinite

## Overview

Retrieve paginated posts from Civitai with full post metadata, associated images, and user engagement data. Ideal
for building social feeds, post browsing interfaces, and content discovery.

## Endpoint

`POST /api/trpc/post.getInfinite`

## Request Parameters

### Core Parameters

| Parameter     | Type   | Default          | Description                                                               |
|---------------|--------|------------------|---------------------------------------------------------------------------|
| limit         | number | 100              | Posts per page (0-200)                                                    |
| cursor        | string | -                | For pagination (use nextCursor from previous response, "value\|id" format)|
| sort          | string | "Most Reactions" | Sort order (see options below)                                            |
| period        | string | "AllTime"        | Time range: "Day", "Week", "Month", "Year", "AllTime"                     |
| periodMode    | string | "published"      | Whether to filter by "stats" or "published" timestamp                     |
| browsingLevel | number | all levels       | Content level bit flags (same as for images)                              |
| query         | string | -                | Search posts by title (prefix matching)                                   |

### Filtering Parameters

| Parameter        | Type     | Description                                |
|------------------|----------|--------------------------------------------|
| collectionId     | number   | Filter to a specific collection            |
| modelVersionId   | number   | Filter to posts for a specific model       |
| username         | string   | Filter to a specific user's posts          |
| tags             | number[] | Filter by tag IDs                          |
| ids              | number[] | Fetch specific post IDs                    |
| excludedTagIds   | number[] | Exclude specific tag IDs                   |
| excludedUserIds  | number[] | Exclude specific user IDs                  |
| excludedImageIds | number[] | Exclude posts containing specific images   |
| followed         | boolean  | Show only posts from followed users        |
| clubId           | number   | Filter to club-exclusive posts             |
| draftOnly        | boolean  | Show only unpublished drafts (owner only)  |
| pending          | boolean  | Include pending/moderation-state posts     |

### Include Options

| Parameter | Type     | Default       | Description                                       |
|-----------|----------|---------------|---------------------------------------------------|
| include   | string[] | ["cosmetics"] | Data to include: "cosmetics", "detail"            |

### Sorting Options

- "Most Reactions" - Most liked/hearted posts (default)
- "Most Comments" - Most discussed posts
- "Most Collected" - Most saved to collections
- "Newest" - Latest posts first

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ],
        "nextCursor": "..."
      }
    }
  }
}
```

### Post Properties (in items)

#### Core Properties

| Field          | Type   | Description                                 |
|----------------|--------|---------------------------------------------|
| id             | number | Unique post identifier                      |
| nsfwLevel      | number | Content level                               |
| title          | string | Post title (nullable)                       |
| userId         | number | ID of post creator                          |
| publishedAt    | string | Publication timestamp (nullable)            |
| modelVersionId | number | Associated model version ID (nullable)      |
| collectionId   | number | Associated collection ID (nullable)         |
| detail         | string | Full post description (if include=detail)   |
| imageCount     | number | Number of images in the post                |
| user           | object | Creator info (see below)                    |
| stats          | object | Statistics (see below)                      |
| images         | array  | Array of images (same as image.getInfinite) |
| cosmetic       | object | Post cosmetic/decoration (nullable)         |

#### Creator Info (user property object)

| Field      | Type   | Description                    |
|------------|--------|--------------------------------|
| id         | number | User ID                        |
| username   | string | Display name                   |
| image      | string | Profile picture URL (nullable) |
| deletedAt  | string | Account deletion date if any   |
| cosmetics  | array  | User cosmetics/decorations     |

#### Engagement (stats property object)

| Field          | Type   | Description      |
|----------------|--------|------------------|
| likeCount      | number | Total likes      |
| dislikeCount   | number | Total dislikes   |
| heartCount     | number | Total hearts     |
| laughCount     | number | Total laughs     |
| cryCount       | number | Total cries      |
| commentCount   | number | Total comments   |
| collectedCount | number | Times collected  |

# post.get

## Overview

Retrieves detailed information about a single post, including tags and user info.

## Endpoint

`POST /api/trpc/post.get`

## Request Parameters

| Parameter | Type   | Description             |
|-----------|--------|-------------------------|
| id        | number | ID of the post to fetch |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field          | Type   | Description                                          |
|----------------|--------|------------------------------------------------------|
| id             | number | Unique post identifier                               |
| nsfwLevel      | number | Content level                                        |
| title          | string | Post title (nullable)                                |
| detail         | string | Post description/body text (nullable)                |
| modelVersionId | number | Associated model version ID (nullable)               |
| publishedAt    | string | Publication timestamp (nullable)                     |
| availability   | string | Visibility status: "Public", "Private", or "Unlisted"|
| collectionId   | number | Associated collection ID (nullable)                  |
| tags           | array  | Array of tag objects (see below)                     |
| user           | object | Creator info (see below)                             |

#### Tag properties

| Field      | Type    | Description                    |
|------------|---------|--------------------------------|
| id         | number  | Tag ID                         |
| name       | string  | Tag name                       |
| isCategory | boolean | Whether this is a category tag |

#### Creator Info (user property object)

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Avatar URL (nullable)               |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |
| cosmetics      | array  | User cosmetics/decorations          |

#### Profile Picture properties (when present)

| Field     | Type   | Description                    |
|-----------|--------|--------------------------------|
| id        | number | Image ID                       |
| url       | string | Image URL                      |
| nsfwLevel | number | NSFW level of image            |
| hash      | string | Image hash (nullable)          |
| type      | string | Media type ("image", "video")  |
| width     | number | Width in pixels (nullable)     |
| height    | number | Height in pixels (nullable)    |

# collection.getAllUser

## Overview

Retrieves all collections for the authenticated user. Requires authentication.

## Endpoint

`POST /api/trpc/collection.getAllUser`

## Request Parameters

| Parameter        | Type     | Default | Description                                              |
|------------------|----------|---------|----------------------------------------------------------|
| contributingOnly | boolean  | true    | Only return collections the user contributes to          |
| permission       | string   | -       | Filter by permission: "VIEW", "ADD", "ADD_REVIEW", "MANAGE" |
| permissions      | string[] | -       | Filter by multiple permissions                           |
| type             | string   | -       | Filter by type: "Model", "Article", "Post", "Image"      |

## Response Format

```
{
  "result": {
    "data": {
      "json": [ ... ]
    }
  }
}
```

### Collection Properties (array items)

| Field        | Type    | Description                                           |
|--------------|---------|-------------------------------------------------------|
| id           | number  | Collection ID                                         |
| name         | string  | Collection name                                       |
| description  | string  | Collection description (nullable)                     |
| type         | string  | Collection type: "Model", "Article", "Post", "Image"  |
| read         | string  | Read access: "Private", "Public", "Unlisted"          |
| write        | string  | Write access: "Private", "Public", "Review"           |
| mode         | string  | Collection mode: "Contest", "Bookmark" (nullable)     |
| nsfw         | boolean | Whether collection contains NSFW content              |
| nsfwLevel    | number  | NSFW level                                            |
| availability | string  | Availability status                                   |
| userId       | number  | Owner's user ID                                       |
| isOwner      | boolean | Whether current user owns this collection             |
| image        | object  | Cover image (nullable, see below)                     |
| tags         | array   | Array of tag objects                                  |
| metadata     | object  | Collection metadata (contest settings, etc.)          |

#### Cover Image properties (when present)

| Field     | Type   | Description                   |
|-----------|--------|-------------------------------|
| id        | number | Image ID                      |
| url       | string | Image URL                     |
| nsfwLevel | number | NSFW level                    |
| width     | number | Width in pixels               |
| height    | number | Height in pixels              |
| hash      | string | Image hash                    |

#### Tag properties

| Field          | Type    | Description                    |
|----------------|---------|--------------------------------|
| id             | number  | Tag ID                         |
| name           | string  | Tag name                       |
| isCategory     | boolean | Whether this is a category tag |
| type           | string  | Tag type                       |
| filterableOnly | boolean | Whether tag is filter-only     |

# collection.getById

## Overview

Retrieves detailed information about a collection, including user permissions.

## Endpoint

`POST /api/trpc/collection.getById`

## Request Parameters

| Parameter | Type   | Description   |
|-----------|--------|---------------|
| id        | number | Collection ID |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "collection": { ... },
        "permissions": { ... }
      }
    }
  }
}
```

### Collection Properties

| Field        | Type    | Description                                           |
|--------------|---------|-------------------------------------------------------|
| id           | number  | Collection ID                                         |
| name         | string  | Collection name                                       |
| description  | string  | Collection description (nullable)                     |
| type         | string  | Collection type: "Model", "Article", "Post", "Image"  |
| read         | string  | Read access: "Private", "Public", "Unlisted"          |
| write        | string  | Write access: "Private", "Public", "Review"           |
| mode         | string  | Collection mode: "Contest", "Bookmark" (nullable)     |
| nsfw         | boolean | Whether collection contains NSFW content              |
| nsfwLevel    | number  | NSFW level                                            |
| availability | string  | Availability status                                   |
| userId       | number  | Owner's user ID                                       |
| user         | object  | Owner info (see below)                                |
| image        | object  | Cover image (nullable, same as getAllUser)            |
| tags         | array   | Array of tag objects (same as getAllUser)             |
| metadata     | object  | Collection metadata (contest settings, etc.)          |

#### Owner Info (user property object)

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Avatar URL (nullable)               |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |
| cosmetics      | array  | User cosmetics/decorations          |

### Permissions Properties

| Field             | Type     | Description                                        |
|-------------------|----------|----------------------------------------------------|
| collectionId      | number   | Collection ID                                      |
| read              | boolean  | Can read collection                                |
| write             | boolean  | Can add to collection                              |
| writeReview       | boolean  | Can add items for review                           |
| manage            | boolean  | Can manage collection                              |
| follow            | boolean  | Can follow collection                              |
| isContributor     | boolean  | User is a contributor                              |
| isOwner           | boolean  | User owns the collection                           |
| followPermissions | string[] | Permissions granted on follow                      |
| publicCollection  | boolean  | Whether collection is public                       |
| collectionType    | string   | Collection type (nullable)                         |
| collectionMode    | string   | Collection mode (nullable)                         |

# image.get

## Overview

Retrieves detailed information about a single image, including user info, stats, and cosmetics.

## Endpoint

`POST /api/trpc/image.get`

## Request Parameters

| Parameter   | Type    | Description                                         |
|-------------|---------|-----------------------------------------------------|
| id          | number  | Image ID to fetch                                   |
| withoutPost | boolean | If true, skip post-level visibility checks (optional)|

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field             | Type    | Description                                               |
|-------------------|---------|-----------------------------------------------------------|
| id                | number  | Unique image identifier                                   |
| name              | string  | Image name (nullable)                                     |
| url               | string  | Image UUID for CDN URL construction                       |
| width             | number  | Image width in pixels (nullable)                          |
| height            | number  | Image height in pixels (nullable)                         |
| hash              | string  | Perceptual hash (nullable)                                |
| type              | string  | Media type: "image" or "video"                            |
| nsfwLevel         | number  | Content level (bit flags)                                 |
| postId            | number  | Associated post ID (nullable)                             |
| index             | number  | Position index within post (nullable)                     |
| hideMeta          | boolean | Whether generation metadata is hidden by creator          |
| createdAt         | string  | Creation timestamp                                        |
| publishedAt       | string  | Publication timestamp                                     |
| mimeType          | string  | MIME type of the file                                     |
| ingestion         | string  | Ingestion status: "Pending", "Scanned", "Error", etc.    |
| availability      | string  | "Public" or "Private"                                     |
| hasMeta           | boolean | Whether image has generation metadata                     |
| hasPositivePrompt | boolean | Whether image has a positive prompt                       |
| onSite            | boolean | Whether image was generated on Civitai                    |
| remixOfId         | number  | Source image ID if this is a remix (nullable)             |
| user              | object  | Creator info (see below)                                  |
| stats             | object  | Engagement statistics (see below)                         |
| reactions         | array   | Current user's reactions on this image                    |
| cosmetic          | object  | Content decoration cosmetic (nullable)                    |

#### Creator Info (user property object)

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Avatar URL (nullable)               |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |
| cosmetics      | array  | User cosmetics/decorations          |

#### Engagement (stats property object)

| Field                 | Type   | Description        |
|-----------------------|--------|--------------------|
| likeCountAllTime      | number | Total likes        |
| laughCountAllTime     | number | Total laughs       |
| heartCountAllTime     | number | Total hearts       |
| cryCountAllTime       | number | Total cries        |
| dislikeCountAllTime   | number | Total dislikes     |
| commentCountAllTime   | number | Total comments     |
| collectedCountAllTime | number | Total collections  |

# reaction.toggle

## Overview

Toggle a reaction on an entity (image, post, comment, etc.). If the reaction already exists, it is removed;
otherwise it is created. Requires authentication. Rate limited.

## Endpoint

`POST /api/trpc/reaction.toggle`

## Request Parameters

| Parameter  | Type   | Description                                                                           |
|------------|--------|---------------------------------------------------------------------------------------|
| entityId   | number | ID of the entity being reacted to                                                     |
| entityType | string | Entity type (see values below)                                                        |
| reaction   | string | Reaction type: "Like", "Dislike", "Heart", "Laugh", "Cry"                             |

### Entity Types

`"question"`, `"answer"`, `"comment"`, `"commentOld"`, `"image"`, `"post"`, `"resourceReview"`, `"article"`,
`"bountyEntry"`, `"clubPost"`

## Response Format

```
{
  "result": {
    "data": {
      "json": "created"
    }
  }
}
```

The response is a string: `"created"` if the reaction was added, `"removed"` if it was toggled off.

## Notes

- Requires authentication (guarded procedure)
- Rate limited (see Rate Limiting section above)
- The frontend typically uses optimistic updates; the response confirms the server state
- Access checks are performed for images/posts linked to private models
- Contest images may have voting period restrictions

# user.getCreator

## Overview

Retrieves a creator's public profile with stats, cosmetics, and rank info. This is the main endpoint for
viewing user profiles.

## Endpoint

`POST /api/trpc/user.getCreator`

## Request Parameters

Provide one of the following to identify the user:

| Parameter     | Type   | Description                |
|---------------|--------|----------------------------|
| username      | string | Username (case-insensitive)|
| id            | number | User ID                    |
| leaderboardId | string | Leaderboard ID             |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field                    | Type    | Description                                    |
|--------------------------|---------|------------------------------------------------|
| id                       | number  | User ID                                        |
| username                 | string  | Display name                                   |
| image                    | string  | Legacy avatar URL (nullable)                   |
| createdAt                | string  | Account creation timestamp                     |
| muted                    | boolean | Whether user is muted                          |
| bannedAt                 | string  | Ban timestamp (nullable)                       |
| deletedAt                | string  | Deletion timestamp (nullable)                  |
| excludeFromLeaderboards  | boolean | Whether excluded from leaderboards             |
| publicSettings           | object  | User's public settings                         |
| links                    | array   | Social links (see below)                       |
| stats                    | object  | User statistics (see below)                    |
| rank                     | object  | Leaderboard rank info (see below)              |
| cosmetics                | array   | Equipped cosmetics                             |
| profilePicture           | object  | Profile picture details (nullable, see below)  |
| _count                   | object  | Counts (see below)                             |

#### Links (array items)

| Field | Type   | Description      |
|-------|--------|------------------|
| url   | string | Link URL         |
| type  | string | Link type/label  |

#### Stats

| Field                    | Type   | Description            |
|--------------------------|--------|------------------------|
| downloadCountAllTime     | number | Total downloads        |
| thumbsUpCountAllTime     | number | Total thumbs up        |
| followerCountAllTime     | number | Total followers        |
| reactionCountAllTime     | number | Total reactions        |
| uploadCountAllTime       | number | Total uploads          |
| generationCountAllTime   | number | Total generations      |

#### Rank

| Field                | Type   | Description                    |
|----------------------|--------|--------------------------------|
| leaderboardRank      | number | Position on leaderboard (nullable) |
| leaderboardId        | string | Leaderboard ID (nullable)      |
| leaderboardTitle     | string | Leaderboard title (nullable)   |
| leaderboardCosmetic  | object | Leaderboard cosmetic (nullable)|

#### Profile Picture (when present)

| Field     | Type   | Description                    |
|-----------|--------|--------------------------------|
| id        | number | Image ID                       |
| url       | string | Image UUID for CDN URL         |
| nsfwLevel | number | NSFW level                     |
| hash      | string | Perceptual hash (nullable)     |
| type      | string | Media type ("image", "video")  |
| width     | number | Width in pixels (nullable)     |
| height    | number | Height in pixels (nullable)    |

#### Counts

| Field  | Type   | Description          |
|--------|--------|----------------------|
| models | number | Number of models     |

## Notes

- Public endpoint, no authentication required
- Returns null if the user is the system user (id: -1 or username: "civitai")
- Cached with short TTL

# user.getById

## Overview

Retrieves basic user info by ID. Returns a simplified user object.

## Endpoint

`POST /api/trpc/user.getById`

## Request Parameters

| Parameter | Type   | Description |
|-----------|--------|-------------|
| id        | number | User ID     |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Properties

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Legacy avatar URL (nullable)        |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |

## Notes

- Public endpoint, no authentication required

# user.toggleFollow

## Overview

Toggle following a user. If not following, creates a follow; if already following, removes it.

## Endpoint

`POST /api/trpc/user.toggleFollow`

## Request Parameters

| Parameter    | Type   | Description                              |
|--------------|--------|------------------------------------------|
| targetUserId | number | ID of the user to follow/unfollow        |
| username     | string | Username for reference (optional, nullable)|

## Response Format

No explicit return value. The toggle is fire-and-forget on the server side.

## Notes

- Requires authentication (verified procedure — email must be verified)
- Creates a "followed-by" notification to the target user
- If user had previously hidden the target user, the hide is converted to a follow
- Grants a daily follow reward (first follow of the day)

# user.getFollowingUsers

## Overview

Retrieves the list of users that the authenticated user is following.

## Endpoint

`POST /api/trpc/user.getFollowingUsers`

## Request Parameters

None. Uses the authenticated user's ID from the session.

## Response Format

```
{
  "result": {
    "data": {
      "json": [ ... ]
    }
  }
}
```

### User Properties (array items)

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Legacy avatar URL (nullable)        |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |

## Notes

- Requires authentication (protected procedure)

# user.updateBrowsingMode

## Overview

Updates the user's content filtering preferences (NSFW settings and browsing level).

## Endpoint

`POST /api/trpc/user.updateBrowsingMode`

## Request Parameters

All parameters are optional. Only provide the fields you want to change.

| Parameter     | Type    | Description                                                     |
|---------------|---------|-----------------------------------------------------------------|
| showNsfw      | boolean | Whether to show NSFW content                                    |
| blurNsfw      | boolean | Whether to blur NSFW content                                    |
| browsingLevel | number  | Content filtering level (bit flags, 0 to 31). See Enums section |

## Response Format

No return value (void mutation). The session is refreshed after the update.

## Notes

- Requires authentication (guarded procedure)
- Refreshes the user's session after updating

# user.toggleFavorite

## Overview

Toggle favoriting a model. When favoriting, also enables notifications for the model and adds it to bookmarks.

## Endpoint

`POST /api/trpc/user.toggleFavorite`

## Request Parameters

| Parameter      | Type    | Description                            |
|----------------|---------|----------------------------------------|
| modelId        | number  | ID of the model to favorite/unfavorite |
| modelVersionId | number  | Specific model version (optional)      |
| setTo          | boolean | true to favorite, false to unfavorite  |

## Response Format

```
{
  "result": {
    "data": {
      "json": true
    }
  }
}
```

Returns a boolean indicating the result.

## Notes

- Requires authentication (protected procedure)
- Returns false if user is muted
- When favoriting (`setTo: true`): also adds model notification and creates a bookmark
- When unfavoriting (`setTo: false`): only removes bookmark if user has no existing reviews for the model

# user.getSettings

## Overview

Retrieves the authenticated user's settings.

## Endpoint

`POST /api/trpc/user.getSettings`

## Request Parameters

None. Uses the authenticated user's ID from the session.

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Properties (all optional/nullable)

| Field                                  | Type    | Description                                |
|----------------------------------------|---------|--------------------------------------------|
| newsletterDialogLastSeenAt             | string  | Last newsletter dialog display             |
| features                               | object  | Feature flag overrides (key: boolean)      |
| newsletterSubscriber                   | boolean | Newsletter subscription status             |
| dismissedAlerts                        | array   | List of dismissed alert IDs                |
| assistantPersonality                   | string  | "civbot" or "civchan"                      |
| allowAds                               | boolean | Whether to show ads                        |
| disableHidden                          | boolean | Whether to disable hidden content          |
| redBrowsingLevel                       | number  | Red domain browsing level                  |
| gallerySettings                        | object  | Gallery filter preferences                 |
| tourSettings                           | object  | Tour completion states                     |
| generation                             | object  | Generation preferences (advancedMode)      |
| preferredFiatCurrency                  | string  | Preferred currency code                    |

## Notes

- Requires authentication (protected procedure)
- Cached server-side

# user.setSettings

## Overview

Updates the authenticated user's settings. Merges with existing settings.

## Endpoint

`POST /api/trpc/user.setSettings`

## Request Parameters

All parameters are optional. Only provide the fields you want to change.

| Parameter                              | Type    | Description                                |
|----------------------------------------|---------|--------------------------------------------|
| allowAds                               | boolean | Whether to show ads                        |
| tourSettings                           | object  | Tour completion states (deep merged)       |
| generation                             | object  | Generation preferences (advancedMode)      |
| assistantPersonality                   | string  | "civbot" or "civchan" (requires feature flag)|
| preferredFiatCurrency                  | string  | Preferred currency code                    |

## Response Format

Returns the updated settings object (same shape as user.getSettings response).

## Notes

- Requires authentication (protected procedure)
- `tourSettings` is deep merged with existing settings
- Clears server-side settings cache after update

# collection.getInfinite

## Overview

Browse public collections with filtering and sorting. Returns paginated results with cover images and contributor counts.

## Endpoint

`POST /api/trpc/collection.getInfinite`

## Request Parameters

### Core Parameters

| Parameter     | Type     | Default   | Description                                               |
|---------------|----------|-----------|-----------------------------------------------------------|
| limit         | number   | -         | Collections per page (0-100)                              |
| cursor        | number   | -         | For pagination (use nextCursor from previous response)    |
| sort          | string   | "Newest"  | Sort order: "Newest", "Most Contributors"                 |
| browsingLevel | number   | -         | Content level bit flags                                   |

### Filtering Parameters

| Parameter       | Type     | Description                                          |
|-----------------|----------|------------------------------------------------------|
| userId          | number   | Filter to a specific user's collections              |
| types           | string[] | Collection types: "Model", "Post", "Image", "Article"|
| privacy         | string[] | Read access filter: "Public", "Unlisted", "Private"  |
| ids             | number[] | Fetch specific collection IDs                        |
| modes           | string[] | Collection modes: "Bookmark", "Contest"              |
| excludedUserIds | number[] | Exclude specific user IDs                            |
| excludedTagIds  | number[] | Exclude specific tag IDs                             |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ],
        "nextCursor": 123
      }
    }
  }
}
```

### Collection Properties (in items)

| Field     | Type   | Description                                              |
|-----------|--------|----------------------------------------------------------|
| id        | number | Collection ID                                            |
| name      | string | Collection name                                          |
| read      | string | Read access: "Private", "Public", "Unlisted"             |
| type      | string | Collection type                                          |
| userId    | number | Owner's user ID                                          |
| nsfwLevel | number | Content level                                            |
| mode      | string | Collection mode (nullable)                               |
| createdAt | string | Creation timestamp                                       |
| user      | object | Owner info (id, username, image, cosmetics)              |
| image     | object | Cover image (nullable)                                   |
| images    | array  | Preview images array                                     |
| metadata  | object | Collection metadata                                      |
| _count    | object | `{ items: number, contributors: number }`                |

## Notes

- Public endpoint but feature-flag protected
- Cursor is a number (collection ID), not a date

# collection.saveItem

## Overview

Add or remove items from collections. Can add to multiple collections and remove from others in a single call.

## Endpoint

`POST /api/trpc/collection.saveItem`

## Request Parameters

Provide exactly one item identifier:

| Parameter              | Type     | Description                                     |
|------------------------|----------|-------------------------------------------------|
| type                   | string   | Collection type (optional): "Model", "Post", "Image", "Article" |
| imageId                | number   | Image ID to save (provide one of these four)    |
| postId                 | number   | Post ID to save                                 |
| modelId                | number   | Model ID to save                                |
| articleId              | number   | Article ID to save                              |
| note                   | string   | Optional note for the saved item                |
| collections            | array    | Collections to add item to (see below)          |
| removeFromCollectionIds| number[] | Collection IDs to remove item from              |

### Collections Array Items

| Parameter    | Type   | Description                     |
|--------------|--------|---------------------------------|
| collectionId | number | Collection ID to add item to    |
| tagId        | number | Tag ID for the item (optional)  |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "status": "added"
      }
    }
  }
}
```

The `status` field will be `"added"`, `"updated"`, or `"removed"`.

## Notes

- Requires authentication (protected procedure, feature-flag protected)
- Only one of imageId/postId/modelId/articleId should be provided

# collection.follow

## Overview

Follow a collection to receive updates.

## Endpoint

`POST /api/trpc/collection.follow`

## Request Parameters

| Parameter    | Type   | Description                               |
|--------------|--------|-------------------------------------------|
| collectionId | number | Collection ID to follow                   |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "userId": 123,
        "collectionId": 456,
        "permissions": [ ... ]
      }
    }
  }
}
```

## Notes

- Requires authentication (protected procedure, feature-flag protected)
- Returns undefined if user has no permission to follow

# collection.unfollow

## Overview

Unfollow a collection.

## Endpoint

`POST /api/trpc/collection.unfollow`

## Request Parameters

| Parameter    | Type   | Description                               |
|--------------|--------|-------------------------------------------|
| collectionId | number | Collection ID to unfollow                 |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "userId": 123,
        "collectionId": 456
      }
    }
  }
}
```

## Notes

- Requires authentication (protected procedure, feature-flag protected)

# collection.getUserCollectionItemsByItem

## Overview

Check which of the authenticated user's collections contain a specific item. Useful for showing "saved to"
indicators in the UI.

## Endpoint

`POST /api/trpc/collection.getUserCollectionItemsByItem`

## Request Parameters

Provide exactly one item identifier, plus optional collection filters:

| Parameter        | Type     | Description                                              |
|------------------|----------|----------------------------------------------------------|
| imageId          | number   | Image ID to check (provide one of these four)            |
| postId           | number   | Post ID to check                                         |
| modelId          | number   | Model ID to check                                        |
| articleId        | number   | Article ID to check                                      |
| contributingOnly | boolean  | Only collections the user contributes to (default: true) |
| type             | string   | Filter by collection type                                |

## Response Format

```
{
  "result": {
    "data": {
      "json": [ ... ]
    }
  }
}
```

### Properties (array items)

| Field        | Type    | Description                                      |
|--------------|---------|--------------------------------------------------|
| collectionId | number  | Collection ID                                    |
| addedById    | number  | User who added the item                          |
| tagId        | number  | Associated tag (nullable)                        |
| collection   | object  | `{ userId: number, read: string }`               |
| canRemoveItem| boolean | Whether the current user can remove this item    |

## Notes

- Requires authentication (protected procedure, feature-flag protected)

# comment.getAll

## Overview

Retrieve paginated comments for a model. This is the v1 comment system used for model-level comments.

## Endpoint

`POST /api/trpc/comment.getAll`

## Request Parameters

| Parameter | Type     | Default   | Description                                              |
|-----------|----------|-----------|----------------------------------------------------------|
| limit     | number   | -         | Comments per page (0-100)                                |
| page      | number   | -         | Page number (offset-based pagination)                    |
| cursor    | number   | -         | For cursor-based pagination                              |
| modelId   | number   | -         | Filter to a specific model                               |
| userId    | number   | -         | Filter to a specific user's comments                     |
| filterBy  | string[] | -         | Filters: "IncludesImages", "NSFW"                        |
| sort      | string   | "Newest"  | Sort: "Newest", "Oldest", "MostLiked", "MostComments"   |
| hidden    | boolean  | false     | Show hidden comments                                     |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "comments": [ ... ],
        "nextCursor": 123
      }
    }
  }
}
```

### Comment Properties (in comments array)

| Field        | Type    | Description                               |
|--------------|---------|-------------------------------------------|
| id           | number  | Comment ID                                |
| createdAt    | string  | Creation timestamp                        |
| content      | string  | HTML content                              |
| nsfw         | boolean | Whether comment is NSFW                   |
| modelId      | number  | Associated model ID                       |
| parentId     | number  | Parent comment ID for replies (nullable)  |
| locked       | boolean | Whether comment is locked                 |
| tosViolation | boolean | Whether comment violates TOS              |
| hidden       | boolean | Whether comment is hidden                 |
| user         | object  | Author info (id, username, image, cosmetics)|
| reactions    | array   | Array of `{ userId, reaction }` objects   |
| model        | object  | `{ name: string }`                        |
| _count       | object  | `{ comments: number }` (reply count)      |

## Notes

- Public endpoint, no authentication required

# commentv2.getInfinite

## Overview

Retrieve threaded comments for any entity type. This is the v2 comment system used for images, posts, articles,
bounties, and more.

## Endpoint

`POST /api/trpc/commentv2.getInfinite`

## Request Parameters

| Parameter       | Type     | Default   | Description                                                  |
|-----------------|----------|-----------|--------------------------------------------------------------|
| entityId        | number   | -         | ID of the entity to get comments for (required)              |
| entityType      | string   | -         | Entity type (required, see values below)                     |
| limit           | number   | 20        | Comments per page (1-100)                                    |
| cursor          | number   | -         | For pagination                                               |
| sort            | string   | "Oldest"  | Sort: "Oldest", "Newest", "MostReactions"                    |
| hidden          | boolean  | -         | Filter by hidden status                                      |
| parentThreadId  | number   | -         | Filter to a specific thread                                  |
| excludedUserIds | number[] | -         | Exclude comments by these users                              |

### Entity Types

`"question"`, `"answer"`, `"image"`, `"post"`, `"model"`, `"comment"`, `"review"`, `"article"`, `"bounty"`,
`"bountyEntry"`, `"clubPost"`, `"challenge"`, `"comicChapter"`

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "comments": [ ... ],
        "nextCursor": 123
      }
    }
  }
}
```

### Comment Properties (in comments array)

| Field         | Type    | Description                               |
|---------------|---------|-------------------------------------------|
| id            | number  | Comment ID                                |
| createdAt     | string  | Creation timestamp                        |
| content       | string  | HTML content                              |
| nsfw          | boolean | Whether comment is NSFW                   |
| tosViolation  | boolean | Whether comment violates TOS              |
| hidden        | boolean | Whether comment is hidden (nullable)      |
| threadId      | number  | Thread ID                                 |
| pinnedAt      | string  | Pin timestamp (nullable)                  |
| reactionCount | number  | Total reaction count                      |
| user          | object  | Author info (id, username, image, profilePicture, cosmetics) |
| reactions     | array   | Array of `{ userId, reaction }` objects   |

## Notes

- Public endpoint
- The v2 comment system supports any entity type, not just models
- Comments are organized into threads via threadId

# commentv2.upsert

## Overview

Create or update a comment on any entity. Uses the v2 comment system.

## Endpoint

`POST /api/trpc/commentv2.upsert`

## Request Parameters

| Parameter       | Type     | Description                                                   |
|-----------------|----------|---------------------------------------------------------------|
| id              | number   | Comment ID (for editing an existing comment, optional)        |
| entityId        | number   | ID of the entity to comment on (required)                     |
| entityType      | string   | Entity type (required, same values as commentv2.getInfinite)  |
| content         | string   | HTML content (required, sanitized — allowed tags: div, strong, p, em, u, s, a, br, span) |
| parentThreadId  | number   | Thread ID to reply to (optional)                              |
| nsfw            | boolean  | Mark comment as NSFW (optional)                               |
| hidden          | boolean  | Mark comment as hidden (optional)                             |

## Response Format

Returns the created/updated comment object (same shape as commentv2.getInfinite comment items).

## Notes

- Requires authentication (guarded procedure)
- Rate limited (see Rate Limiting section)
- Content is HTML-sanitized — only allowed tags: `div`, `strong`, `p`, `em`, `u`, `s`, `a`, `br`, `span`
- Content must be non-empty and not just `<p></p>`

# comment.toggleReaction

## Overview

Toggle a reaction on a v1 comment.

## Endpoint

`POST /api/trpc/comment.toggleReaction`

## Request Parameters

| Parameter | Type   | Description                                        |
|-----------|--------|----------------------------------------------------|
| id        | number | Comment ID                                         |
| reaction  | string | Reaction type: "Like", "Dislike", "Heart", "Laugh", "Cry" |

## Response Format

Returns the toggled reaction result.

## Notes

- Requires authentication (protected procedure)
- For v2 comments, use `reaction.toggle` with `entityType: "comment"` instead

# model.getById

## Overview

Retrieves comprehensive details about a model, including all versions, metrics, and generation coverage info.

## Endpoint

`POST /api/trpc/model.getById`

## Request Parameters

| Parameter           | Type    | Description                                   |
|---------------------|---------|-----------------------------------------------|
| id                  | number  | Model ID (required)                           |
| excludeTrainingData | boolean | Skip training data in response (default: false)|

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field                  | Type    | Description                                          |
|------------------------|---------|------------------------------------------------------|
| id                     | number  | Model ID                                             |
| name                   | string  | Model name                                           |
| description            | string  | Model description (nullable)                         |
| type                   | string  | Model type (see Model Types in Enums section)        |
| nsfw                   | boolean | Whether model is NSFW                                |
| nsfwLevel              | number  | Content level (bit flags)                            |
| status                 | string  | "Draft", "Published", "Unpublished", etc.            |
| checkpointType         | string  | Checkpoint type (nullable)                           |
| publishedAt            | string  | Publication timestamp (nullable)                     |
| locked                 | boolean | Whether model is locked for editing                  |
| mode                   | string  | Model modifier (nullable)                            |
| availability           | string  | "Public", "Private", "Unsearchable", "EarlyAccess"  |
| allowNoCredit          | boolean | Allow use without credit (nullable)                  |
| allowCommercialUse     | array   | Commercial use permissions (nullable)                |
| allowDerivatives       | boolean | Allow derivative works (nullable)                    |
| allowDifferentLicense  | boolean | Allow different licenses (nullable)                  |
| user                   | object  | Creator info (see below)                             |
| modelVersions          | array   | Array of model versions (see below)                  |
| rank                   | object  | Aggregated metrics (see below)                       |
| canGenerate            | boolean | Whether model supports on-site generation            |

#### Creator Info

| Field          | Type   | Description                         |
|----------------|--------|-------------------------------------|
| id             | number | User ID                             |
| username       | string | Display name                        |
| image          | string | Avatar URL (nullable)               |
| deletedAt      | string | Account deletion date (nullable)    |
| profilePicture | object | Profile picture details (nullable)  |
| cosmetics      | array  | Equipped cosmetics                  |
| rank           | object | `{ leaderboardRank: number }`       |

#### Model Version Properties (in modelVersions array)

| Field           | Type     | Description                                     |
|-----------------|----------|-------------------------------------------------|
| id              | number   | Version ID                                      |
| modelId         | number   | Parent model ID                                 |
| name            | string   | Version name                                    |
| description     | string   | Version description (nullable)                  |
| baseModel       | string   | Base model (e.g., "SD 1.5", "SDXL", "Flux.1 D")|
| status          | string   | Version status                                  |
| publishedAt     | string   | Publication timestamp (nullable)                |
| trainedWords    | string[] | Trigger words for the model                     |
| steps           | number   | Training steps (nullable)                       |
| epochs          | number   | Training epochs (nullable)                      |
| clipSkip        | number   | CLIP skip (nullable)                            |
| nsfwLevel       | number   | Content level                                   |
| createdAt       | string   | Creation timestamp                              |
| requireAuth     | boolean  | Whether download requires authentication        |

#### Rank (aggregated metrics)

| Field                      | Type   | Description          |
|----------------------------|--------|----------------------|
| downloadCountAllTime       | number | Total downloads      |
| thumbsUpCountAllTime       | number | Total thumbs up      |
| thumbsDownCountAllTime     | number | Total thumbs down    |
| commentCountAllTime        | number | Total comments       |
| tippedAmountCountAllTime   | number | Total tips           |
| imageCountAllTime          | number | Total images         |
| collectedCountAllTime      | number | Total collections    |
| generationCountAllTime     | number | Total generations    |

## Notes

- Public endpoint, no authentication required
- Model versions are filtered based on user permissions (non-owners can't see drafts)
- Includes generation coverage info per version

# model.getAll

## Overview

Browse and search models with comprehensive filtering, sorting, and pagination.

## Endpoint

`POST /api/trpc/model.getAll`

## Request Parameters

### Core Parameters

| Parameter         | Type     | Default          | Description                                                     |
|-------------------|----------|------------------|-----------------------------------------------------------------|
| limit             | number   | -                | Models per page (0-100)                                         |
| cursor            | varies   | -                | For pagination (number, bigint, date, or string)                |
| query             | string   | -                | Search by model name                                            |
| sort              | string   | "Highest Rated"  | Sort order (see Model Sort in Enums section)                    |
| period            | string   | "AllTime"        | Time range for metrics                                          |
| periodMode        | string   | -                | "published" or "updated"                                        |
| browsingLevel     | number   | -                | Content level bit flags                                         |

### Filtering Parameters

| Parameter          | Type     | Description                                          |
|--------------------|----------|------------------------------------------------------|
| types              | string[] | Model types (see Model Types in Enums section)       |
| status             | string[] | Model statuses: "Draft", "Published", etc.           |
| checkpointType     | string   | Checkpoint type filter                               |
| baseModels         | string[] | Base model identifiers                               |
| ids                | number[] | Fetch specific model IDs                             |
| modelVersionIds    | number[] | Filter by model version IDs                          |
| username           | string   | Filter by username                                   |
| tag                | string   | Filter by tag name                                   |
| favorites          | boolean  | Show only favorited models (default: false)          |
| hidden             | boolean  | Show only hidden models (default: false)             |
| followed           | boolean  | Show only from followed users                        |
| earlyAccess        | boolean  | Filter early access models                           |
| supportsGeneration | boolean  | Filter by generation support                         |
| fromPlatform       | boolean  | Filter by platform origin                            |
| collectionId       | number   | Filter to a specific collection                      |
| availability       | string   | "Public", "Private", "Unsearchable", "EarlyAccess"  |
| isFeatured         | boolean  | Only featured models                                 |
| excludedTagIds     | number[] | Exclude specific tag IDs                             |
| excludedUserIds    | number[] | Exclude specific user IDs                            |

### Licensing Filters

| Parameter              | Type     | Description                        |
|------------------------|----------|------------------------------------|
| allowNoCredit          | boolean  | Allow use without credit           |
| allowCommercialUse     | string[] | Commercial use permissions         |
| allowDerivatives       | boolean  | Allow derivative works             |
| allowDifferentLicense  | boolean  | Allow different licenses           |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ],
        "nextCursor": "..."
      }
    }
  }
}
```

### Model Properties (in items)

Same structure as model.getById response, but may have fewer enriched fields depending on the query.

## Notes

- Public endpoint, no authentication required
- Edge cached
- Uses infinite scroll (cursor-based) pagination only — no page parameter

# model-version.getById

## Overview

Retrieves detailed information about a specific model version, including training details and recommended resources.

## Endpoint

`POST /api/trpc/modelVersion.getById`

## Request Parameters

| Parameter | Type    | Description                                        |
|-----------|---------|----------------------------------------------------|
| id        | number  | Model version ID (required)                        |
| withFiles | boolean | Include file and post data (optional, default: false)|

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        <properties>
      }
    }
  }
}
```

### Core Properties

| Field              | Type     | Description                                          |
|--------------------|----------|------------------------------------------------------|
| id                 | number   | Version ID                                           |
| name               | string   | Version name                                         |
| description        | string   | Version description (nullable)                       |
| baseModel          | string   | Base model identifier                                |
| baseModelType      | string   | Base model type (nullable)                           |
| status             | string   | Version status                                       |
| trainedWords       | string[] | Trigger words                                        |
| steps              | number   | Training steps (nullable)                            |
| epochs             | number   | Training epochs (nullable)                           |
| clipSkip           | number   | CLIP skip (nullable)                                 |
| createdAt          | string   | Creation timestamp                                   |
| publishedAt        | string   | Publication timestamp (nullable)                     |
| nsfwLevel          | number   | Content level                                        |
| requireAuth        | boolean  | Whether download requires authentication             |
| trainingStatus     | string   | Training status (nullable)                           |
| trainingDetails    | object   | Training parameters (nullable)                       |
| model              | object   | Parent model info (see below)                        |
| recommendedResources| array   | Recommended companion resources                      |
| generationCoverage | object   | `{ covered: boolean }` (nullable)                    |

#### Parent Model Info

| Field        | Type   | Description                      |
|--------------|--------|----------------------------------|
| id           | number | Model ID                         |
| name         | string | Model name                       |
| type         | string | Model type                       |
| status       | string | Model status                     |
| nsfw         | boolean| Whether model is NSFW            |
| availability | string | Availability status              |
| user         | object | `{ id: number }`                 |

## Notes

- Public endpoint, no authentication required
- The `withFiles` parameter significantly increases response size

# tag.getAll

## Overview

Retrieve tags with optional search and filtering. Useful for tag autocomplete and browsing.

## Endpoint

`POST /api/trpc/tag.getAll`

## Request Parameters

| Parameter     | Type     | Default | Description                                              |
|---------------|----------|---------|----------------------------------------------------------|
| limit         | number   | 20      | Tags per page (1-200)                                    |
| page          | number   | 1       | Page number                                              |
| query         | string   | -       | Search tags by name                                      |
| entityType    | string[] | -       | Filter by target: "Model", "Image", "Post", "Article"   |
| types         | string[] | -       | Filter by tag type                                       |
| modelId       | number   | -       | Tags associated with a model                             |
| excludedTagIds| number[] | -       | Exclude specific tag IDs                                 |
| categories    | boolean  | -       | Only return category tags                                |
| nsfwLevel     | number   | -       | Filter by NSFW level                                     |
| sort          | string   | -       | Sort order                                               |
| include       | string[] | -       | Include extra fields: "nsfwLevel", "isCategory"          |
| withModels    | boolean  | false   | Include associated model IDs                             |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ]
      }
    }
  }
}
```

### Tag Properties (in items)

| Field      | Type    | Description                            |
|------------|---------|----------------------------------------|
| id         | number  | Tag ID                                 |
| name       | string  | Tag name                               |
| isCategory | boolean | Whether this is a category tag (if included)|
| nsfwLevel  | number  | NSFW level (if included)               |
| models     | array   | Associated model IDs (if withModels)   |

## Notes

- Public endpoint, no authentication required
- Uses offset-based pagination (page/limit)

# tag.getTrending

## Overview

Retrieve currently trending tags for a specific entity type.

## Endpoint

`POST /api/trpc/tag.getTrending`

## Request Parameters

| Parameter     | Type     | Default | Description                                              |
|---------------|----------|---------|----------------------------------------------------------|
| entityType    | string[] | -       | Entity types to get trending tags for (required): "Model", "Image", "Post", "Article" |
| limit         | number   | -       | Maximum tags to return                                   |
| includeNsfw   | boolean  | -       | Include NSFW tags                                        |
| excludedTagIds| number[] | -       | Exclude specific tag IDs                                 |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ]
      }
    }
  }
}
```

### Tag Properties (in items)

Same shape as tag.getAll response items.

## Notes

- Public endpoint, no authentication required

# notification.getAllByUser

## Overview

Retrieve the authenticated user's notifications with cursor-based pagination.

## Endpoint

`POST /api/trpc/notification.getAllByUser`

## Request Parameters

All parameters are optional.

| Parameter | Type    | Default | Description                              |
|-----------|---------|---------|------------------------------------------|
| limit     | number  | -       | Notifications per page                   |
| cursor    | string  | -       | For pagination (ISO date from nextCursor)|
| unread    | boolean | false   | Only show unread notifications           |
| category  | string  | -       | Filter by notification category          |

## Response Format

```
{
  "result": {
    "data": {
      "json": {
        "items": [ ... ],
        "nextCursor": "2024-03-22T10:52:00.000Z"
      }
    }
  }
}
```

### Notification Properties (in items)

| Field     | Type    | Description                                      |
|-----------|---------|--------------------------------------------------|
| id        | number  | Notification ID                                  |
| type      | string  | Notification type identifier                     |
| category  | string  | Notification category                            |
| details   | object  | Notification-specific details (varies by type)   |
| createdAt | string  | Creation timestamp                               |
| read      | boolean | Whether notification has been read               |

## Notes

- Requires authentication (protected procedure)
- Cursor is a date (ISO format)
- The `details` object varies based on notification type (e.g., "followed-by" includes userId/username)

# notification.markRead

## Overview

Mark notifications as read, either individually, by category, or all at once.

## Endpoint

`POST /api/trpc/notification.markRead`

## Request Parameters

| Parameter | Type    | Description                                              |
|-----------|---------|----------------------------------------------------------|
| id        | number  | Mark a specific notification as read                     |
| all       | boolean | Mark all notifications as read                           |
| category  | string  | When combined with `all`, mark only this category as read|

Provide either `id` for a single notification, or `all: true` for bulk marking.

## Response Format

No explicit return value (void mutation).

## Notes

- Requires authentication (protected procedure)
- Cache is invalidated based on the scope of the operation

