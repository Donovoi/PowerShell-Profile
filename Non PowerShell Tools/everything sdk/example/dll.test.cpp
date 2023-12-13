
// Everything IPC test
// this tests the lib and the dll.

#include <iostream>
using namespace std;

#include "..\include\Everything.h"

int main(int argc,char **argv)
{
	Everything_SetSearchW(L"hello");
	Everything_QueryW(TRUE);

	{
		DWORD i;

		for(i=0;i<Everything_GetNumResults();i++)
		{
			wcout << Everything_GetResultFileNameW(i) << L"\n";
		}
	}

	return 0;
}
