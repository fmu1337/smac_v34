#include <shell>

// Minimal stand-ins for the SourceMod natives the loader uses, reading the BSP from g_iFile.
#define PLATFORM_MAX_PATH 256
#define SEEK_SET 0
#define INVALID_HANDLE Handle:0
#include "data.inc"
new g_iPos;
stock Handle:OpenFile(const String:file[], const String:mode[]) { g_iPos = 0; return Handle:1; }
stock CloseHandle(Handle:h) {}
stock bool:FileSeek(Handle:h, pos, where) { g_iPos = pos; return (pos % 4) == 0 && pos <= g_iFileWords * 4; }
stock ReadFile(Handle:h, items[], num, size)
{
	if (size != 4) return -1;
	new i;
	for (i = 0; i < num && g_iPos / 4 < g_iFileWords; i++) { items[i] = g_iFile[g_iPos / 4]; g_iPos += 4; }
	return i;
}
stock strcopy(String:dest[], maxlen, const String:src[]) { new i; for (; i < maxlen - 1 && src[i]; i++) dest[i] = src[i]; dest[i] = 0; return i; }
stock SubtractVectors(const Float:a[3], const Float:b[3], Float:c[3]) { c[0] = a[0] - b[0]; c[1] = a[1] - b[1]; c[2] = a[2] - b[2]; }
stock Format(String:buf[], maxlen, const String:fmt[], any:...) { strcopy(buf, maxlen, fmt); }

#include <smac_wallhack_occ>

public main()
{
	decl String:sError[128];
	if (!Occ_Load("x", sError, sizeof(sError))) { printf("load failed: %s\n", sError); return; }
	printf("kept %d rejected %d wedges %d (python %d)\n", g_iOccKept, g_iOccRejected, g_iOccOdd, g_iExpectKept);
	new iBad;
	for (new i = 0; i < g_iExpectKept; i++) if (!g_iOccBrushCount[g_iExpectBrush[i]]) iBad++;
	printf("python brushes missing in SP: %d\n", iBad);
	iBad = 0;
	for (new i = 0; i < g_iNumQ; i++) if (Occ_PointLeaf(g_fQ[i]) != g_iQLeaf[i]) iBad++;
	printf("leaf mismatches: %d of %d\n", iBad, g_iNumQ);
	iBad = 0;
	new iBlocked;
	for (new i = 0; i < g_iNumQ; i++)
	{
		new bool:b = Occ_SegmentBlocked(g_iSBrush[i], g_fSA[i], g_fSB[i]);
		if (b != g_bSBlocked[i]) iBad++;
		if (b) iBlocked++;
	}
	printf("segment mismatches: %d of %d (%d blocked)\n", iBad, g_iNumQ, iBlocked);
	iBad = 0;
	new iFound;
	decl iOut[8];
	for (new i = 0; i < g_iNumQ; i++)
	{
		new n = Occ_RayCandidates(g_fQ[i], g_fQ[g_iRayEnd[i]], iOut, 8);
		iFound += n;
		for (new k = 0; k < 8; k++)
		{
			if ((k < n ? iOut[k] : -1) != g_iRayExpect[i][k]) { iBad++; break; }
		}
	}
	printf("ray candidate mismatches: %d of %d (%d candidates)\n", iBad, g_iNumQ, iFound);
}
