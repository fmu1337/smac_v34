/**
 * Occluders from the map's BSP for smac_wallhack.
 *
 * Idea from CornerCulling (github.com/87andrewh/CornerCulling): an enemy is hidden for sure when a single convex
 * solid blocks every line of sight to him. CornerCulling places such solids (cuboids) by hand for each map; here
 * they are the map's own world brushes, which are convex by construction (an intersection of half-spaces).
 *
 * The plugin keeps its engine traces. The occluders only prove "hidden" earlier and cheaper: a brush that blocks
 * every segment the traces would test (from each eye to each sample point) means every one of those traces would
 * be blocked too, so the answer is the same and the traces can be skipped.
 *
 * Only opaque world brushes are kept: solid, not window/grate/translucent/water, with at least one drawn side and
 * no translucent side. Brush entities (doors, breakables) aren't in the world tree and are never used.
 */

#if defined _smac_wallhack_occ_included
	#endinput
#endif
#define _smac_wallhack_occ_included

#define OCC_MAX_PLANES			65536
#define OCC_MAX_NODES			65536
#define OCC_MAX_LEAFS			65536
#define OCC_MAX_LEAFBRUSHES		65536
#define OCC_MAX_BRUSHES			8192
#define OCC_MAX_SIDES			65536
#define OCC_MAX_TEXINFO			12288

#define OCC_LUMP_PLANES			1
#define OCC_LUMP_NODES			5
#define OCC_LUMP_TEXINFO		6
#define OCC_LUMP_LEAFS			10
#define OCC_LUMP_MODELS			14
#define OCC_LUMP_LEAFBRUSHES	17
#define OCC_LUMP_BRUSHES		18
#define OCC_LUMP_BRUSHSIDES		19

#define OCC_CONTENTS_SOLID			0x1
#define OCC_CONTENTS_REJECT			0x10000032	// TRANSLUCENT | WATER | SLIME | WINDOW
#define OCC_CONTENTS_GRATE			0x8
#define OCC_SURF_TRANS				0x10
#define OCC_SURF_NODRAW				0x80

// Brushes are shrunk by this much, so a line that only grazes an edge never counts as blocked.
#define OCC_SHRINK				1.0

new bool:g_bOccLoaded;
new g_iOccHeadNode;
new g_iOccNumNodes;
new g_iOccNumLeafs;
new g_iOccNumBrushes;
new g_iOccKept;
new g_iOccRejected;

new Float:g_fOccPlane[OCC_MAX_PLANES * 4];		// normal xyz, dist
new g_iOccNode[OCC_MAX_NODES * 3];				// plane, front child, back child (< 0: leaf -1 - n)
new g_iOccLeaf[OCC_MAX_LEAFS * 2];				// first leafbrush, leafbrush count
new g_iOccLeafBrush[OCC_MAX_LEAFBRUSHES];
new g_iOccBrushFirst[OCC_MAX_BRUSHES];			// into g_iOccSidePlane
new g_iOccBrushCount[OCC_MAX_BRUSHES];			// 0 = not an occluder
new Float:g_fOccBrushMins[OCC_MAX_BRUSHES * 3];
new Float:g_fOccBrushMaxs[OCC_MAX_BRUSHES * 3];
new g_iOccSidePlane[OCC_MAX_SIDES];

// Load-time scratch.
new g_iOccBuf[4096];
new g_iOccLumps[64 * 4];
new g_iOccTexFlags[OCC_MAX_TEXINFO];
new g_iOccSides[OCC_MAX_SIDES * 2];				// raw dbrushside_t words

/**
 * Loads the occluders of the current map. Returns false (occluders off) on any unexpected data.
 */
stock bool:Occ_Load(const String:map[], String:error[], maxlen)
{
	g_bOccLoaded = false;
	g_iOccKept = 0;
	g_iOccRejected = 0;
	
	decl String:sPath[PLATFORM_MAX_PATH];
	Format(sPath, sizeof(sPath), "maps/%s.bsp", map);
	
	new Handle:hFile = OpenFile(sPath, "rb");
	
	if (hFile == INVALID_HANDLE)
	{
		Format(error, maxlen, "can't open %s", sPath);
		return false;
	}
	
	new bool:bResult = Occ_Parse(hFile, error, maxlen);
	CloseHandle(hFile);
	
	g_bOccLoaded = bResult;
	return bResult;
}

stock bool:Occ_Parse(Handle:hFile, String:error[], maxlen)
{
	// Header: ident, version, lump_t[64] { fileofs, filelen, version, fourCC }.
	if (ReadFile(hFile, g_iOccBuf, 2, 4) != 2 || ReadFile(hFile, g_iOccLumps, sizeof(g_iOccLumps), 4) != sizeof(g_iOccLumps))
	{
		strcopy(error, maxlen, "short header");
		return false;
	}
	
	if (g_iOccBuf[0] != 0x50534256 || g_iOccBuf[1] < 19 || g_iOccBuf[1] > 21)
	{
		Format(error, maxlen, "not a VBSP v19-21 (version %d)", g_iOccBuf[1]);
		return false;
	}
	
	new iCount, iWords, i, j, base;
	
	// Planes: normal[3], dist, type.
	if (!Occ_Lump(hFile, OCC_LUMP_PLANES, 20, OCC_MAX_PLANES, iCount, error, maxlen))
		return false;
	
	new iNumPlanes = iCount;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / 5)
	{
		iWords = Occ_Chunk(hFile, iCount - i, 5);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "planes");
		
		for (j = 0; j < iWords; j++)
		{
			base = (i + j) * 4;
			g_fOccPlane[base] = Float:g_iOccBuf[j * 5];
			g_fOccPlane[base + 1] = Float:g_iOccBuf[j * 5 + 1];
			g_fOccPlane[base + 2] = Float:g_iOccBuf[j * 5 + 2];
			g_fOccPlane[base + 3] = Float:g_iOccBuf[j * 5 + 3];
		}
	}
	
	// Texinfo: textureVecs[8], lightmapVecs[8], flags, texdata.
	if (!Occ_Lump(hFile, OCC_LUMP_TEXINFO, 72, OCC_MAX_TEXINFO, iCount, error, maxlen))
		return false;
	
	new iNumTexinfo = iCount;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / 18)
	{
		iWords = Occ_Chunk(hFile, iCount - i, 18);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "texinfo");
		
		for (j = 0; j < iWords; j++)
		{
			g_iOccTexFlags[i + j] = g_iOccBuf[j * 18 + 16];
		}
	}
	
	// Nodes: planenum, children[2], mins/maxs (shorts), firstface/numfaces, area/padding.
	if (!Occ_Lump(hFile, OCC_LUMP_NODES, 32, OCC_MAX_NODES, iCount, error, maxlen))
		return false;
	
	g_iOccNumNodes = iCount;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / 8)
	{
		iWords = Occ_Chunk(hFile, iCount - i, 8);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "nodes");
		
		for (j = 0; j < iWords; j++)
		{
			base = (i + j) * 3;
			g_iOccNode[base] = g_iOccBuf[j * 8];
			g_iOccNode[base + 1] = g_iOccBuf[j * 8 + 1];
			g_iOccNode[base + 2] = g_iOccBuf[j * 8 + 2];
		}
	}
	
	// Leafs: 56 bytes with ambient lighting (lump version 0, old v19 maps), 32 bytes otherwise.
	// firstleafbrush and numleafbrushes are the two shorts at byte 24 either way.
	new iLeafSize = (g_iOccLumps[OCC_LUMP_LEAFS * 4 + 2] == 0) ? 56 : 32;
	
	if (!Occ_Lump(hFile, OCC_LUMP_LEAFS, iLeafSize, OCC_MAX_LEAFS, iCount, error, maxlen))
		return false;
	
	g_iOccNumLeafs = iCount;
	new iLeafWords = iLeafSize / 4;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / iLeafWords)
	{
		iWords = Occ_Chunk(hFile, iCount - i, iLeafWords);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "leafs");
		
		for (j = 0; j < iWords; j++)
		{
			base = g_iOccBuf[j * iLeafWords + 6];
			g_iOccLeaf[(i + j) * 2] = base & 0xFFFF;
			g_iOccLeaf[(i + j) * 2 + 1] = (base >> 16) & 0xFFFF;
		}
	}
	
	// Leafbrushes: unsigned shorts, read in pairs.
	if (!Occ_Lump(hFile, OCC_LUMP_LEAFBRUSHES, 2, OCC_MAX_LEAFBRUSHES, iCount, error, maxlen))
		return false;
	
	new iNumLeafBrushes = iCount;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) * 2)
	{
		iWords = Occ_Chunk(hFile, (iCount - i + 1) / 2, 1);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "leafbrushes");
		
		for (j = 0; j < iWords; j++)
		{
			g_iOccLeafBrush[i + j * 2] = g_iOccBuf[j] & 0xFFFF;
			
			if (i + j * 2 + 1 < OCC_MAX_LEAFBRUSHES)
			{
				g_iOccLeafBrush[i + j * 2 + 1] = (g_iOccBuf[j] >> 16) & 0xFFFF;
			}
		}
	}
	
	// Brush sides: planenum (ushort), texinfo (short), dispinfo (short), bevel.
	if (!Occ_Lump(hFile, OCC_LUMP_BRUSHSIDES, 8, OCC_MAX_SIDES, iCount, error, maxlen))
		return false;
	
	new iNumSides = iCount;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / 2)
	{
		iWords = Occ_Chunk(hFile, iCount - i, 2);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "brushsides");
		
		for (j = 0; j < iWords * 2; j++)
		{
			g_iOccSides[i * 2 + j] = g_iOccBuf[j];
		}
	}
	
	// World model's head node: dmodel_t { mins[3], maxs[3], origin[3], headnode, firstface, numfaces }.
	if (!Occ_Lump(hFile, OCC_LUMP_MODELS, 48, 65536, iCount, error, maxlen))
		return false;
	
	if (iCount < 1 || Occ_Chunk(hFile, 1, 12) != 1)
		return Occ_Fail(error, maxlen, "models");
	
	g_iOccHeadNode = g_iOccBuf[9];
	
	// The tree must stay inside the arrays, or a lookup could read garbage or never end.
	if (g_iOccHeadNode < 0 || g_iOccHeadNode >= g_iOccNumNodes)
		return Occ_Fail(error, maxlen, "head node");
	
	for (i = 0; i < g_iOccNumNodes; i++)
	{
		if (g_iOccNode[i * 3] < 0 || g_iOccNode[i * 3] >= iNumPlanes)
			return Occ_Fail(error, maxlen, "node plane");
		
		for (j = 1; j <= 2; j++)
		{
			base = g_iOccNode[i * 3 + j];
			
			if (base >= g_iOccNumNodes || (base < 0 && -1 - base >= g_iOccNumLeafs))
				return Occ_Fail(error, maxlen, "node child");
		}
	}
	
	for (i = 0; i < g_iOccNumLeafs; i++)
	{
		if (g_iOccLeaf[i * 2] + g_iOccLeaf[i * 2 + 1] > iNumLeafBrushes)
			return Occ_Fail(error, maxlen, "leaf brushes");
	}
	
	// Brushes: firstside, numsides, contents.
	if (!Occ_Lump(hFile, OCC_LUMP_BRUSHES, 12, OCC_MAX_BRUSHES, iCount, error, maxlen))
		return false;
	
	g_iOccNumBrushes = iCount;
	
	for (i = 0; i < iNumLeafBrushes; i++)
	{
		if (g_iOccLeafBrush[i] >= g_iOccNumBrushes)
			return Occ_Fail(error, maxlen, "leafbrush index");
	}
	
	new iNext;
	
	for (i = 0; i < iCount; i += sizeof(g_iOccBuf) / 3)
	{
		iWords = Occ_Chunk(hFile, iCount - i, 3);
		
		if (iWords < 0)
			return Occ_Fail(error, maxlen, "brushes");
		
		for (j = 0; j < iWords; j++)
		{
			new iFirst = g_iOccBuf[j * 3];
			new iNum = g_iOccBuf[j * 3 + 1];
			new iContents = g_iOccBuf[j * 3 + 2];
			
			g_iOccBrushCount[i + j] = 0;
			
			if (iFirst < 0 || iNum < 0 || iFirst + iNum > iNumSides)
				return Occ_Fail(error, maxlen, "brush sides");
			
			if (!(iContents & OCC_CONTENTS_SOLID) || (iContents & (OCC_CONTENTS_REJECT | OCC_CONTENTS_GRATE)))
				continue;
			
			iNext = Occ_AddBrush(i + j, iFirst, iNum, iNext, iNumPlanes, iNumTexinfo);
		}
	}
	
	// Every brush has its axial planes and the centre of its box inside it. Many failures mean a misread file.
	if (g_iOccRejected * 10 > g_iOccKept + g_iOccRejected)
	{
		Format(error, maxlen, "%d of %d brushes failed the plane check", g_iOccRejected, g_iOccKept + g_iOccRejected);
		g_iOccKept = 0;
		return false;
	}
	
	return true;
}

/**
 * Keeps one brush as an occluder if it's opaque. Returns the next free slot in g_iOccSidePlane.
 */
stock Occ_AddBrush(brush, first, num, next, numPlanes, numTexinfo)
{
	new bool:bDrawn, iPlanes, iPlane, iTexinfo, iFlags;
	new start = next;
	
	for (new k = 0; k < 3; k++)
	{
		g_fOccBrushMins[brush * 3 + k] = 1.0;
		g_fOccBrushMaxs[brush * 3 + k] = -1.0;
	}
	
	for (new s = first; s < first + num; s++)
	{
		iPlane = g_iOccSides[s * 2] & 0xFFFF;
		iTexinfo = (g_iOccSides[s * 2] >> 16) & 0xFFFF;
		
		if (iTexinfo >= 0x8000)
		{
			iTexinfo -= 0x10000;
		}
		
		if (iPlane >= numPlanes)
			return start;
		
		// Axial planes (bevels included) give the bounding box, for drawing only.
		for (new k = 0; k < 3; k++)
		{
			if (g_fOccPlane[iPlane * 4 + k] == 1.0)
			{
				g_fOccBrushMaxs[brush * 3 + k] = g_fOccPlane[iPlane * 4 + 3];
			}
			else if (g_fOccPlane[iPlane * 4 + k] == -1.0)
			{
				g_fOccBrushMins[brush * 3 + k] = -g_fOccPlane[iPlane * 4 + 3];
			}
		}
		
		// Bevels are extra planes for collision; they never cut the brush.
		if ((g_iOccSides[s * 2 + 1] >> 16) & 0xFF)
			continue;
		
		iFlags = (iTexinfo >= 0 && iTexinfo < numTexinfo) ? g_iOccTexFlags[iTexinfo] : OCC_SURF_NODRAW;
		
		if (iFlags & OCC_SURF_TRANS)
			return start;
		
		if (!(iFlags & OCC_SURF_NODRAW))
		{
			bDrawn = true;
		}
		
		if (next + iPlanes >= OCC_MAX_SIDES)
			return start;
		
		g_iOccSidePlane[next + iPlanes] = iPlane;
		iPlanes++;
	}
	
	// All-nodraw solids (tools/toolsinvisible and the like) can be see-through: never use them.
	if (!bDrawn || iPlanes < 4)
		return start;
	
	// Sanity check: a complete box from the axial planes, and its centre inside every side.
	decl Float:vCentre[3];
	
	for (new k = 0; k < 3; k++)
	{
		if (g_fOccBrushMins[brush * 3 + k] > g_fOccBrushMaxs[brush * 3 + k])
		{
			g_iOccRejected++;
			return start;
		}
		
		vCentre[k] = (g_fOccBrushMins[brush * 3 + k] + g_fOccBrushMaxs[brush * 3 + k]) * 0.5;
	}
	
	for (new s = start; s < start + iPlanes; s++)
	{
		iPlane = g_iOccSidePlane[s] * 4;
		
		if (g_fOccPlane[iPlane] * vCentre[0] + g_fOccPlane[iPlane + 1] * vCentre[1] + g_fOccPlane[iPlane + 2] * vCentre[2] - g_fOccPlane[iPlane + 3] > 0.01)
		{
			g_iOccRejected++;
			return start;
		}
	}
	
	g_iOccBrushFirst[brush] = start;
	g_iOccBrushCount[brush] = iPlanes;
	g_iOccKept++;
	
	return start + iPlanes;
}

stock bool:Occ_Fail(String:error[], maxlen, const String:what[])
{
	Format(error, maxlen, "bad %s", what);
	return false;
}

/**
 * Seeks to a lump and returns its record count. Compressed lumps and oversized ones are refused.
 */
stock bool:Occ_Lump(Handle:hFile, lump, size, max, &count, String:error[], maxlen)
{
	new iOffset = g_iOccLumps[lump * 4];
	new iLength = g_iOccLumps[lump * 4 + 1];
	
	if (g_iOccLumps[lump * 4 + 3] != 0)
	{
		Format(error, maxlen, "lump %d is compressed", lump);
		return false;
	}
	
	if (iOffset < 0 || iLength < 0 || iLength % size != 0 || iLength / size > max)
	{
		Format(error, maxlen, "lump %d has a bad size", lump);
		return false;
	}
	
	if (!FileSeek(hFile, iOffset, SEEK_SET))
	{
		Format(error, maxlen, "can't seek to lump %d", lump);
		return false;
	}
	
	count = iLength / size;
	return true;
}

/**
 * Reads up to `left` records of `words` int32 each into g_iOccBuf. Returns the number read, -1 on a short read.
 */
stock Occ_Chunk(Handle:hFile, left, words)
{
	new iRecords = sizeof(g_iOccBuf) / words;
	
	if (iRecords > left)
	{
		iRecords = left;
	}
	
	if (ReadFile(hFile, g_iOccBuf, iRecords * words, 4) != iRecords * words)
		return -1;
	
	return iRecords;
}

/**
 * Leaf of the world tree that holds a point.
 */
stock Occ_PointLeaf(const Float:pos[3])
{
	new iNode = g_iOccHeadNode, iPlane;
	
	// A valid tree is far shallower than this; the cap only guards against a cycle in a broken file.
	for (new iDepth = 0; iNode >= 0 && iDepth < 1024; iDepth++)
	{
		iPlane = g_iOccNode[iNode * 3] * 4;
		
		if (g_fOccPlane[iPlane] * pos[0] + g_fOccPlane[iPlane + 1] * pos[1] + g_fOccPlane[iPlane + 2] * pos[2] >= g_fOccPlane[iPlane + 3])
		{
			iNode = g_iOccNode[iNode * 3 + 1];
		}
		else
		{
			iNode = g_iOccNode[iNode * 3 + 2];
		}
	}
	
	return (iNode < 0) ? -1 - iNode : -1;
}

/**
 * Does the segment a-b pass through the (shrunk) brush? Clips it against each side plane.
 */
stock bool:Occ_SegmentBlocked(brush, const Float:a[3], const Float:b[3])
{
	new Float:fEnter = 0.0, Float:fLeave = 1.0, Float:fA, Float:fB, Float:fT;
	new iEnd = g_iOccBrushFirst[brush] + g_iOccBrushCount[brush], iPlane;
	
	for (new s = g_iOccBrushFirst[brush]; s < iEnd; s++)
	{
		iPlane = g_iOccSidePlane[s] * 4;
		
		fA = g_fOccPlane[iPlane] * a[0] + g_fOccPlane[iPlane + 1] * a[1] + g_fOccPlane[iPlane + 2] * a[2] - g_fOccPlane[iPlane + 3] + OCC_SHRINK;
		fB = g_fOccPlane[iPlane] * b[0] + g_fOccPlane[iPlane + 1] * b[1] + g_fOccPlane[iPlane + 2] * b[2] - g_fOccPlane[iPlane + 3] + OCC_SHRINK;
		
		if (fA > 0.0 && fB > 0.0)
			return false;
		
		if (fA <= 0.0 && fB <= 0.0)
			continue;
		
		fT = fA / (fA - fB);
		
		if (fA > 0.0)
		{
			if (fT > fEnter)
			{
				fEnter = fT;
			}
		}
		else if (fT < fLeave)
		{
			fLeave = fT;
		}
		
		if (fEnter > fLeave)
			return false;
	}
	
	return true;
}
