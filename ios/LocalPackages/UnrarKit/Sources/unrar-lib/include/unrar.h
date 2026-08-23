#ifndef UNRAR_C_H
#define UNRAR_C_H

#include <stdint.h>
#include <wchar.h>

/* Error codes */
#define ERAR_SUCCESS             0
#define ERAR_END_ARCHIVE        10
#define ERAR_NO_MEMORY          11
#define ERAR_BAD_DATA           12
#define ERAR_BAD_ARCHIVE        13
#define ERAR_UNKNOWN_FORMAT     14
#define ERAR_EOPEN              15
#define ERAR_ECREATE            16
#define ERAR_ECLOSE             17
#define ERAR_EREAD              18
#define ERAR_EWRITE             19
#define ERAR_SMALL_BUF          20
#define ERAR_UNKNOWN            21
#define ERAR_MISSING_PASSWORD   22
#define ERAR_EREFERENCE         23
#define ERAR_BAD_PASSWORD       24

/* Open modes */
#define RAR_OM_LIST              0
#define RAR_OM_EXTRACT           1
#define RAR_OM_LIST_INCSPLIT     2

/* Process operations */
#define RAR_SKIP              0
#define RAR_TEST              1
#define RAR_EXTRACT           2

/* Header flags */
#define RHDF_SPLITBEFORE 0x01
#define RHDF_SPLITAFTER  0x02
#define RHDF_ENCRYPTED   0x04
#define RHDF_SOLID       0x10
#define RHDF_DIRECTORY   0x20

#pragma pack(push, 1)

struct RARHeaderDataEx
{
  char         ArcName[1024];
  wchar_t      ArcNameW[1024];
  char         FileName[1024];
  wchar_t      FileNameW[1024];
  unsigned int Flags;
  unsigned int PackSize;
  unsigned int PackSizeHigh;
  unsigned int UnpSize;
  unsigned int UnpSizeHigh;
  unsigned int HostOS;
  unsigned int FileCRC;
  unsigned int FileTime;
  unsigned int UnpVer;
  unsigned int Method;
  unsigned int FileAttr;
  char         *CmtBuf;
  unsigned int CmtBufSize;
  unsigned int CmtSize;
  unsigned int CmtState;
  unsigned int DictSize;
  unsigned int HashType;
  char         Hash[32];
  unsigned int RedirType;
  wchar_t      *RedirName;
  unsigned int RedirNameSize;
  unsigned int DirTarget;
  unsigned int MtimeLow;
  unsigned int MtimeHigh;
  unsigned int CtimeLow;
  unsigned int CtimeHigh;
  unsigned int AtimeLow;
  unsigned int AtimeHigh;
  unsigned int Reserved[988];
};

struct RAROpenArchiveDataEx
{
  char         *ArcName;
  wchar_t      *ArcNameW;
  unsigned int  OpenMode;
  unsigned int  OpenResult;
  char         *CmtBuf;
  unsigned int  CmtBufSize;
  unsigned int  CmtSize;
  unsigned int  CmtState;
  unsigned int  Flags;
  void         *Callback;
  long          UserData;
  unsigned int  OpFlags;
  wchar_t      *CmtBufW;
  unsigned int  Reserved[25];
};

#pragma pack(pop)

#ifdef __cplusplus
extern "C" {
#endif

void *RAROpenArchiveEx(struct RAROpenArchiveDataEx *ArchiveData);
int   RARCloseArchive(void *hArcData);
int   RARReadHeaderEx(void *hArcData, struct RARHeaderDataEx *HeaderData);
int   RARProcessFile(void *hArcData, int Operation, char *DestPath, char *DestName);
int   RARProcessFileW(void *hArcData, int Operation, wchar_t *DestPath, wchar_t *DestName);

#ifdef __cplusplus
}
#endif

#endif /* UNRAR_C_H */
