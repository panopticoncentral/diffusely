# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

The source code for the APIs (and the Civitai website in general) is available as a peer of this project, in the
directory called "civitai". You can look at the source code there to understand better how the APIs work.

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

