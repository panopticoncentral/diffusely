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
  // MostTipped = 'Most Buzz',
  MostComments = 'Most Comments',
  MostCollected = 'Most Collected',
  Newest = 'Newest',
  Oldest = 'Oldest',
  Random = 'Random',
}

# APIs

These are the tRPC APIs accessible from the `https://civitai.com/api/trpc/` endpoint.

## images.getInfinite

### Input Schema (Parameters)

{
  // Base query parameters
  browsingLevel: number; // min: 0, default: 0

  // Image filtering parameters
  baseModels?: BaseModel[]; // Array of base model types
  collectionId?: number;
  collectionTagId?: number;
  hideAutoResources?: boolean;
  hideManualResources?: boolean;
  followed?: boolean; // Show only followed users
  fromPlatform?: boolean;
  hidden?: boolean;
  modelId?: number;
  modelVersionId?: number;
  notPublished?: boolean;
  postId?: number;
  prioritizedUserIds?: number[]; // Users to prioritize in results
  reactions?: ReviewReaction[]; // Filter by reaction types
  scheduled?: boolean;
  tags?: number[]; // Tag IDs to filter by
  techniques?: number[]; // Technique IDs
  tools?: number[]; // Tool IDs
  types?: MediaType[]; // Image/video types
  userId?: number;
  username?: string;
  withMeta?: boolean; // default: false
  requiringMeta?: boolean;

  // Pagination & sorting
  limit?: number; // min: 0, max: 200, default: 50
  cursor?: bigint | number | string | Date; // For pagination
  period?: MetricTimeframe; // default: AllTime
  periodMode?: 'stats' | 'published';
  sort?: ImageSort; // default: MostReactions

  // Advanced filtering
  excludedTagIds?: number[];
  excludedUserIds?: number[];
  generation?: ImageGenerationProcess[];
  ids?: number[]; // Specific image IDs
  imageId?: number;
  include?: ImageInclude[]; // default: ['cosmetics']
  includeBaseModel?: boolean;
  pending?: boolean;
  postIds?: number[];
  reviewId?: number;
  skip?: number;
  withTags?: boolean;
  remixOfId?: number;
  remixesOnly?: boolean;
  nonRemixesOnly?: boolean;
  disablePoi?: boolean;
  disableMinor?: boolean;

  // Moderator only
  poiOnly?: boolean;
  minorOnly?: boolean;

  // Index usage
  useIndex?: boolean; // Whether to use search index vs database
}

### Response Format

{
  nextCursor?: bigint | number | string | Date;
  items: Image[]; // Array of image objects with included data
}
