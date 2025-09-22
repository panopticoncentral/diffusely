# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

# image.getInfinite

## Overview

Retrieve paginated images from Civitai with powerful filtering and sorting options. Perfect for building
galleries, feeds, or browsing interfaces.

## Endpoint

`POST /api/trpc/image.getInfinite`

## Request Parameters

### Essential Parameters

| Parameter | Type   | Default  | Description                                            |
|-----------|--------|----------|--------------------------------------------------------|
| limit     | number | 50       | Images per page (1-200)                                |
| sort      | string | "Newest" | Sort order (see options below)                         |
| cursor    | string | -        | For pagination (use nextCursor from previous response) |

#### Sorting Options

- "Newest" - Latest uploads first
- "Oldest" - Oldest uploads first
- "Most Reactions" - Most liked/hearted
- "Most Comments" - Most discussed
- "Most Collected" - Most saved to collections
- "Random" - Random order

### Content Filters

| Parameter      | Type     | Description                                         |
|----------------|----------|-----------------------------------------------------|
| types          | string[] | ["image", "video", "audio"]                         |
| followed       | boolean  | Limited to followed users                           |
| collectionId   | number   | Filter by collection                                |
| modelId        | number   | Filter by AI model                                  |
| modelVersionId | number   | Filter by model version                             |
| postId         | number   | Filter by post                                      |
| userId         | number   | Filter by creator                                   |
| username       | string   | Filter by creator username                          |
| tags           | number[] | Include images with these tag IDs                   |
| excludedTagIds | number[] | Exclude images with these tag IDs                   |
| baseModels     | string[] | AI models: ["SD 1.5", "SDXL 1.0", "Pony", "Flux.1"] |

### Time & Quality Filters

| Parameter     | Type    | Description                                                         |
|---------------|---------|---------------------------------------------------------------------|
| period        | string  | Time range: "Day", "Week", "Month", "Year", "AllTime"               |
| browsingLevel | number  | Content level flags G = 0, PG = 1, PG13 = 2, R = 4, X = 8, XXX = 16 |
| withMeta      | boolean | Include AI generation parameters                                    |
| requiringMeta | boolean | Only images with generation data                                    |

### Additional Data

| Parameter | Type     | Description                                                  |
|-----------|----------|--------------------------------------------------------------|
| include   | string[] | Extra data: ["tags", "cosmetics", "meta", "profilePictures"] |
| withTags  | boolean  | Include tag information                                      |
| reactions | string[] | Filter by reactions: ["Like", "Heart", "Laugh", "Cry"]       |

## Response Format

```
{
  "result": {
    "data": {
      "items": [ ... ],
      "nextCursor": "..."
    }
  }
}
```

### Image Properties (in items)

#### Core Properties

| Field     | Type    | Description                              |
| --------- | ------- | ---------------------------------------- |
| id        | number  | Unique image identifier                  |
| name      | string  | Image name (can be null)                 |
| url       | string  | Direct image URL                         |
| width     | number  | Image width                              |
| height    | number  | Image height                             |
| nsfwLevel | number  | Content level                            |
| type      | string  | Content type ("image", "video", "audio") |
| postId    | number  | ID of post the image is part of          |
| hash      | number  | Image hash                               |
| user      | object  | Creator info (see below)                 |
| stats     | object  | Statistics (see below)                   |
| hasMeta   | boolean | Has object in the meta property          |
| meta      | object  | AI generation data (see below)           |

#### Creator Info (user property object)

| Field    | Type   | Description         |
| -------- | ------ | ------------------- |
| id       | number | User ID             |
| username | string | Display name        |
| image    | string | Profile picture URL |

#### Engagement (stats property object)

| Field                 | Type   | Description                |
| --------------------- | ------ | -------------------------- |
| likeCountAllTime      | number | Total likes                |
| heartCountAllTime     | number | Total hearts               |
| commentCountAllTime   | number | Total comments             |
| collectedCountAllTime | number | Total collections saved to |

#### AI Generation Data (meta property object)

##### Text Prompts

| Field          | Type   | Description                                  |
|----------------|--------|----------------------------------------------|
| prompt         | string | Primary text prompt used for generation      |
| negativePrompt | string | Negative prompt to exclude unwanted elements |

##### Generation Settings

| Field    | Type   | Description                                          |
|----------|--------|------------------------------------------------------|
| cfgScale | number | Classifier-Free Guidance scale (typically 1-30)      |
| steps    | number | Number of denoising steps (typically 20-150)         |
| sampler  | string | Sampling method (e.g., "DPM++ 2M Karras", "Euler a") |
| seed     | number | Random seed for reproducible generation              |
| clipSkip | number | CLIP skip layers (typically 1-2)                     |

##### Model Information

| Field     | Type                   | Description                                            |
|-----------|------------------------|--------------------------------------------------------|
| baseModel | string                 | Base model used (e.g., "SD 1.5", "SDXL 1.0", "Flux.1") |
| hashes    | Record<string, string> | Model file hashes for verification                     |
| engine    | string                 | Generation engine/platform used                        |
| version   | string                 | Software/model version                                 |
| software  | string                 | Software used for generation                           |

##### Resource Arrays

resources - Generic Resources

```
{
  type: string;        // Resource type (e.g., "lora", "embedding")
  name?: string;       // Resource name
  weight?: number;     // Strength/weight applied
  hash?: string;       // File hash
}[]
```

civitaiResources - Civitai-Specific Resources

```
{
  type?: string;           // Resource type
  weight?: number;         // Strength applied
  modelVersionId: number;  // Civitai model version ID
}[]
```

additionalResources - Extended Resources

```
{
  name?: string;         // Resource name
  type?: string;         // Resource type
  strength?: number;     // Primary strength
  strengthClip?: number; // CLIP strength (for some resource types)
}[]
```

##### Workflow Data

comfy - ComfyUI Workflows

Can be either a string (JSON) or parsed object containing:

```
{
  prompt?: Record<string, any>;    // ComfyUI prompt structure
  workflow?: {
    nodes?: Record<string, any>[]; // Workflow nodes
  };
}
```

external - External Service Data

```
{
  source?: {
    name?: string;      // Service name
    homepage?: string;  // Service URL
  };
  details?: Record<string, string | number | boolean>; // Custom parameters
  createUrl?: string;     // URL to recreate
  referenceUrl?: string;  // Source reference URL
}
```

##### Effects & Control

| Field       | Type                | Description                        |
|-------------|---------------------|------------------------------------|
| effects     | Record<string, any> | Custom effects and filters applied |
| controlNets | string[]            | ControlNet models used             |

##### Processing Info

| Field    | Type   | Description                          |
|----------|--------|--------------------------------------|
| workflow | string | Workflow identifier or configuration |
| process  | string | Processing method used               |
| type     | string | Generation type/category             |

##### Remix Data

| Field           | Type   | Description                             |
|-----------------|--------|-----------------------------------------|
| extra.remixOfId | number | ID of original image if this is a remix |

# post.getInfinite

## Overview

Retrieve paginated posts from Civitai with full post metadata, associated images, and user engagement data. Ideal
for building social feeds, post browsing interfaces, and content discovery.

## Endpoint

`POST /api/trpc/post.getInfinite`

## Request Parameters

### Essential Parameters

| Parameter | Type     | Default  | Description                                            |
|-----------|----------|----------|--------------------------------------------------------|
| limit     | number   | 100      | Posts per page (1-200)                                 |
| sort      | string   | "Newest" | Sort order (see options below)                         |
| cursor    | number   | -        | For pagination (use nextCursor from previous response) |
| include   | string[] |          | Extra data: ["cosmetics"]                              |

#### Sorting Options

- "Newest" - Latest posts first
- "Most Reactions" - Most liked/hearted posts
- "Most Comments" - Most discussed posts
- "Most Collected" - Most saved to collections

### Content Filters

| Parameter        | Type     | Description                               |
|------------------|----------|-------------------------------------------|
| query            | string   | Search posts by text content              |
| username         | string   | Filter by creator username                |
| tags             | number[] | Include posts with these tag IDs          |
| excludedTagIds   | number[] | Exclude posts with these tag IDs          |
| excludedUserIds  | number[] | Exclude posts from these users            |
| excludedImageIds | number[] | Exclude posts containing these images     |
| modelVersionId   | number   | Filter by AI model version                |
| collectionId     | number   | Filter by collection                      |
| clubId           | number   | Filter by club posts                      |
| ids              | number[] | Get specific posts by IDs                 |
| browsingLevel    | number   | Content level flags (same as for images)  |

## Response Format

  {
    "result": {
      "data": {
        "items": [ ... ],
        "nextCursor": "..."
      }
    }
  }

### Core Properties

| Field      | Type   | Description                                 |
| ---------- | ------ | ------------------------------------------- |
| id         | number | Unique post identifier                      |
| name       | string | Post title (can be null)                    |
| detail     | string | Post description                            |
| nsfwLevel  | number | Content level                               |
| imageCount | number | Number of images                            |
| user       | object | Creator info (same as image.getInfinite)    |
| stats      | object | Statistics (see below)                      |
| images     | array  | Array of images (same as image.getInfinite) |

#### Engagement (stats property object)

| Field        | Type   | Description    |
| -------------| ------ | -------------- |
| likeCount    | number | Total likes    |
| heartCount   | number | Total hearts   |
| commentCount | number | Total comments |
| dislikeCount | number | Total dislikes |
| laughCount   | number | Total laughs   |
| cryCount     | number | Total cries    |