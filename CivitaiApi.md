# Datatypes

export const MetricTimeframe = {
  Day: 'Day',
  Week: 'Week',
  Month: 'Month',
  Year: 'Year',
  AllTime: 'AllTime',
} as const;

export enum ImageSort {
  MostReactions = 'Most Reactions',
  MostComments = 'Most Comments',
  MostCollected = 'Most Collected',
  Newest = 'Newest',
  Oldest = 'Oldest',
  Random = 'Random',
}

export const MediaType = {
  image: 'image',
  video: 'video',
  audio: 'audio',
} as const;

const imageInclude = z.enum([
  'tags',
  'count',
  'cosmetics',
  'report',
  'meta',
  'tagIds',
  'profilePictures',
  'metaSelect',
]);

type ImageMetadata = {
  height: number;
  width: number;
  hash?: string;
  size?: number; // File size in bytes
  ruleId?: number;
  ruleReason?: string;
  profilePicture?: boolean;
  username?: string;
  userId?: number;
  skipScannedAtReassignment?: boolean;
}

type VideoMetadata = {
  // Inherited from shared metadata
  height: number;
  width: number;
  hash?: string;
  size?: number; // File size in bytes
  ruleId?: number;
  ruleReason?: string;
  profilePicture?: boolean;
  username?: string;
  userId?: number;
  skipScannedAtReassignment?: boolean;

  // Video-specific properties
  duration?: number; // Duration in seconds
  audio?: boolean; // Whether video has audio track
  thumbnailFrame?: number | null; // Frame to use for thumbnail
  youtubeVideoId?: string;
  youtubeUploadAttempt?: number;
  youtubeUploadEnqueuedAt?: string;
  vimeoVideoId?: string;
  vimeoUploadAttempt?: number;
  vimeoUploadEnqueuedAt?: string;
  thumbnailId?: number;
  parentId?: number;
}

# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

## image.getInfinite

### Input Schema (Parameters)

{
  browsingLevel: number; // Limit the explicitness of the returned images. G = 0, PG = 1, PG13 = 2, R = 4, X = 8, XXX = 16

  collectionId?: number;
  followed?: boolean; // Show only followed users
  limit?: number; // min: 0, max: 200, default: 50
  modelId?: number;
  modelVersionId?: number;
  period?: MetricTimeframe; // default: AllTime
  postId?: number;
  sort?: ImageSort; // default: MostReactions
  tags?: number[]; // Tag IDs to filter by
  types?: MediaType[]; // Image/video types
  userId?: number;
  username?: string;
  withMeta?: boolean; // default: false

  cursor?: bigint | number | string | Date; // For pagination
  include?: ImageInclude[];
  includeBaseModel?: boolean;
  postIds?: number[];
  skip?: number;
  withTags?: boolean;

}

### Response Format

{
  nextCursor?: bigint | number | string | Date;
  items: Image[]; // Array of image objects with included data
}

Each image in the items array contains:

{
  id: number;
  name: string | null;
  url: string;
  nsfwLevel: number; // G = 0, PG = 1, PG13 = 2, R = 4, X = 8, XXX = 16
  width: number | null;
  height: number | null;
  hash: string | null;
  hasMeta: boolean;
  hasPositivePrompt: boolean;
  onSite: boolean; // Generated on Civitai vs external
  remixOfId: number | null;
  createdAt: Date;
  sortAt: Date; // Used for sorting (max of publishedAt, scannedAt, createdAt)
  mimeType: string | null;
  type: MediaType;
  metadata: ImageMetadata | VideoMetadata | null;
  index: number | null; // Order within post
  minor: boolean;
  acceptableMinor: boolean;

  // Post-related fields
  postId: number;
  postTitle: string | null;
  publishedAt: Date | null;
  modelVersionId: number | null;
  availability: Availability;

  // Optional fields (based on include parameter)
  meta?: ImageMetaProps | null; // When include contains 'metaSelect'
  baseModel?: string; // When includeBaseModel is true
  //tags?: VotableTagModel[]; // When include contains 'tags'
  tagIds?: number[]; // When include contains 'tagIds'

  // User information
  user: {
    id: number;
    username: string | null;
    image: string | null; // Profile picture URL
    deletedAt: Date | null;
    // cosmetics: ContentDecorationCosmetic[]; // When include contains 'cosmetics'
    // profilePicture: ProfileImage | null; // When include contains 'profilePictures'
  };

  // Statistics
  stats: {
    likeCountAllTime: number;
    laughCountAllTime: number;
    heartCountAllTime: number;
    cryCountAllTime: number;
    commentCountAllTime: number;
    collectedCountAllTime: number;
    tippedAmountCountAllTime: number;
  };

  // User-specific data (when authenticated)
  //reactions: Array<{
  //  userId: number;
  //  reaction: ReviewReactions;
  //}>;

  // Additional optional fields
  // cosmetic?: WithClaimKey<ContentDecorationCosmetic> | null;
  thumbnailUrl?: string;
}

ImageGenerationProps are

{
    // Prompts
    prompt?: string;
    negativePrompt?: string;

    // Generation Settings
    cfgScale?: number; // Classifier Free Guidance scale
    steps?: number; // Number of diffusion steps
    sampler?: string; // Sampling method (e.g., "DPM++ 2M Karras")
    seed?: number; // Random seed for reproducible generation
    clipSkip?: number; // CLIP skip parameter
    "Clip skip"?: number; // Alternative naming

    // Model Information
    baseModel?: BaseModel; // Base model type (SD1.5, SDXL, etc.)
    hashes?: Record<string, string>; // Model hashes

    // Platform/Engine Info
    engine?: string; // Generation engine used
    version?: string; // Engine version
    process?: string; // Process type
    type?: string; // Generation type
    workflow?: string; // Workflow name

    // ComfyUI Specific
    comfy?: string | ComfyMetaSchema; // ComfyUI workflow data (JSON string or object)

    // External Platform Data
    external?: ExternalMetaSchema; // External platform metadata

    // Effects and Processing
    effects?: Record<string, any>; // Applied effects/filters

    // Resources Used
    resources?: Array<{
      type: string;
      name?: string;
      weight?: number;
      hash?: string;
    }>;

    additionalResources?: Array<{
      name?: string;
      type?: string;
      strength?: number;
      strengthClip?: number;
    }>;

    civitaiResources?: Array<{
      type?: string;
      weight?: number;
      modelVersionId: number;
    }>;

    // Additional Data
    extra?: {
      remixOfId?: number; // ID of original image if this is a remix
    };

    // Extensible - any other unknown properties
    [key: string]: unknown;
  }