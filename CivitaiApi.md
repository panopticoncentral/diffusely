# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

# image.getInfinite

## Overview

Retrieve paginated images from Civitai with powerful filtering and sorting options. Perfect for building
galleries, feeds, or browsing interfaces.

## Endpoint

`POST /api/trpc/image.getInfinite`

## Request Parameters

| Parameter     | Type     | Default  | Description                                                         |
|---------------|----------|----------|---------------------------------------------------------------------|
| limit         | number   | 50       | Images per page (1-200)                                             |
| sort          | string   | "Newest" | Sort order (see options below)                                      |
| cursor        | string   | -        | For pagination (use nextCursor from previous response)              |
| useIndex      | boolean  | false    | Whether to use the index to look up images                          |
| types         | string[] |          | ["image", "video", "audio"]                                         |
| period        | string   |          | Time range: "Day", "Week", "Month", "Year", "AllTime"               |
| browsingLevel | number   |          | Content level flags G = 0, PG = 1, PG13 = 2, R = 4, X = 8, XXX = 16 |
| postId        | number   |          | ID of post to filter to                                             |
| collectionId  | number   |          | ID of collection to filter to                                       |

#### Sorting Options

- "Newest" - Latest uploads first
- "Oldest" - Oldest uploads first
- "Most Reactions" - Most liked/hearted
- "Most Comments" - Most discussed
- "Most Collected" - Most saved to collections
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

| Field     | Type    | Description                              |
| --------- | ------- | ---------------------------------------- |
| id        | number  | Unique image identifier                  |
| url       | string  | Direct image URL                         |
| width     | number  | Image width                              |
| height    | number  | Image height                             |
| nsfwLevel | number  | Content level                            |
| type      | string  | Content type ("image", "video", "audio") |
| postId    | number  | The post that the image belongs to       |
| user      | object  | Creator info (see below)                 |
| stats     | object  | Statistics (see below)                   |

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
| commentCountAllTime      | number | Total comments             |
| collectedCountAllTime    | number | Total collections saved to |
| tippedAmountCountAllTime | number | Total tips                 |
| dislikeCountAllTime      | number | Total dislikes             |
| viewCountAllTime         | number | Total view count           |

# image.getGenerationData

## Overview

Retrieves the generation information for an image or video.

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

| Field     | Type   | Description                                                      |
|-----------|--------|------------------------------------------------------------------|
| type      | string | Content type ("image", "video", "audio")                         |
| meta      | object | Generation parameters (see meta object below)                    |
| resources | array  | List of resources used in generation (see resource object below) |

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

#### Resource properties

| Field       | Type   | Description                                             |
|-------------|--------|---------------------------------------------------------|
| modelId     | number | The model ID of the model used                          |
| modelName   | string | The name of the model                                   |
| modelType   | string | The type of the model (i.e. "Checkpoint", "LORA", etc.) |
| versionId   | number | The version ID of the model used                        |
| versionName | string | The name of the model version                           |
| strength    | number | The strength of the model in the generation             |

# post.getInfinite

## Overview

Retrieve paginated posts from Civitai with full post metadata, associated images, and user engagement data. Ideal
for building social feeds, post browsing interfaces, and content discovery.

## Endpoint

`POST /api/trpc/post.getInfinite`

## Request Parameters

| Parameter     | Type   | Default  | Description                                            |
|---------------|--------|----------|--------------------------------------------------------|
| limit         | number | 100      | Posts per page (1-200)                                 |
| sort          | string | "Newest" | Sort order (see options below)                         |
| cursor        | number | -        | For pagination (use nextCursor from previous response) |
| browsingLevel | number |          | Content level flags (same as for images)               |
| collectionId  | number |          | ID of collection to filter to                          |

#### Sorting Options

- "Newest" - Latest posts first
- "Most Reactions" - Most liked/hearted posts
- "Most Comments" - Most discussed posts
- "Most Collected" - Most saved to collections

## Response Format

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

### Core Properties

| Field      | Type   | Description                                 |
| ---------- | ------ | ------------------------------------------- |
| id         | number | Unique post identifier                      |
| nsfwLevel  | number | Content level                               |
| title      | string | Post title (can be null)                    |
| imageCount | number | Number of images                            |
| user       | object | Creator info (same as image.getInfinite)    |
| stats      | object | Statistics (see below)                      |
| images     | array  | Array of images (same as image.getInfinite) |

### Engagement (stats property object)

| Field        | Type   | Description    |
| -------------| ------ | -------------- |
| cryCount     | number | Total cries    |
| likeCount    | number | Total likes    |
| heartCount   | number | Total hearts   |
| laughCount   | number | Total laughs   |
| commentCount | number | Total comments |
| dislikeCount | number | Total dislikes |

# post.get

## Overview

Retrieves information about a post.

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

| Field      | Type   | Description                                 |
| ---------- | ------ | ------------------------------------------- |
| id         | number | Unique post identifier                      |
| nsfwLevel  | number | Content level                               |
| title      | string | Post title (can be null)                    |
| user       | object | Creator info (same as image.getInfinite)    |

# collection.getAllUser

## Overview

Retrives all the user's collections.

## Endpoint

`POST /api/trpc/collection.getAllUser`

## Request Parameters

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

### Core Properties

| Field | Type   | Description   |
|-------|--------|---------------|
| id    | number | Collection ID |

# collection.getById

## Overview

Retrieves information about a collection.

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
      "collection": { ... }
    }
  }
}
```

### Core Properties

| Field       | Type   | Description                        |
|-------------|--------|------------------------------------|
| id          | number | Collection ID                      |
| name        | string | Collection name                    |
| description | string | Collection description             |
| type        | string | "Article", "Post", "Image" "Model" |

