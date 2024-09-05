#include <stdio.h>
#include <string>
#include <vector>
#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
#include <conio.h>
#include <io.h>
#else
#include <cstring>
#include <dirent.h>
#include <sys/time.h>
#endif

#include <fstream>
#include <streambuf>
#include <iostream>
#include <sstream>

#include "DynamsoftCaptureVisionRouter.h"
#include "DynamsoftUtility.h"

using namespace std;

using namespace dynamsoft::cvr;
using namespace dynamsoft::dlr;
using namespace dynamsoft::dcp;
using namespace dynamsoft::license;
using namespace dynamsoft::basic_structures;
using namespace dynamsoft::utility;

bool GetImagePath(char *pImagePath)
{
	std::string input;
	while (true)
	{
		std::cout << "\n>> Step 1: Input your image file's full path:\n";
		std::getline(std::cin, input);

		// Trim whitespace and remove surrounding quotes if present
		input.erase(0, input.find_first_not_of(" \t\n\r\"\'")); // Trim leading
		input.erase(input.find_last_not_of(" \t\n\r\"\'") + 1); // Trim trailing

		// Exit if user inputs 'q' or 'Q'
		if (input == "q" || input == "Q")
		{
			return true; // Exit flag
		}

		// Copy input to pImagePath ensuring not to exceed buffer size
		std::strncpy(pImagePath, input.c_str(), 511);
		pImagePath[511] = '\0'; // Ensure null-termination

		// Check if file exists using std::ifstream
		std::ifstream file(pImagePath);
		if (file.good())
		{
			file.close();
			return false; // File path is valid
		}

		std::cout << "Please input a valid path.\n";
	}
}

class MRZResult
{
public:
	string docId;
	string docType;
	string nationality;
	string issuer;
	string dateOfBirth;
	string dateOfExpiry;
	string gender;
	string surname;
	string givenname;

	vector<string> rawText;

	MRZResult FromParsedResultItem(const CParsedResultItem *item)
	{
		docType = item->GetCodeType();

		if (docType == "MRTD_TD3_PASSPORT")
		{
			if (item->GetFieldValidationStatus("passportNumber") != VS_FAILED && item->GetFieldValue("passportNumber") != NULL)
			{
				docId = item->GetFieldValue("passportNumber");
			}
		}
		else if (item->GetFieldValidationStatus("documentNumber") != VS_FAILED && item->GetFieldValue("documentNumber") != NULL)
		{
			docId = item->GetFieldValue("documentNumber");
		}

		string line;
		if (docType == "MRTD_TD1_ID")
		{
			if (item->GetFieldValue("line1") != NULL)
			{
				line = item->GetFieldValue("line1");
				if (item->GetFieldValidationStatus("line1") == VS_FAILED)
				{
					line += ", Validation Failed";
				}
				rawText.push_back(line);
			}

			if (item->GetFieldValue("line2") != NULL)
			{
				line = item->GetFieldValue("line2");
				if (item->GetFieldValidationStatus("line2") == VS_FAILED)
				{
					line += ", Validation Failed";
				}
				rawText.push_back(line);
			}

			if (item->GetFieldValue("line3") != NULL)
			{
				line = item->GetFieldValue("line3");
				if (item->GetFieldValidationStatus("line3") == VS_FAILED)
				{
					line += ", Validation Failed";
				}
				rawText.push_back(line);
			}
		}
		else
		{
			if (item->GetFieldValue("line1") != NULL)
			{
				line = item->GetFieldValue("line1");
				if (item->GetFieldValidationStatus("line1") == VS_FAILED)
				{
					line += ", Validation Failed";
				}
				rawText.push_back(line);
			}

			if (item->GetFieldValue("line2") != NULL)
			{
				line = item->GetFieldValue("line2");
				if (item->GetFieldValidationStatus("line2") == VS_FAILED)
				{
					line += ", Validation Failed";
				}
				rawText.push_back(line);
			}
		}

		if (item->GetFieldValidationStatus("nationality") != VS_FAILED && item->GetFieldValue("nationality") != NULL)
		{
			nationality = item->GetFieldValue("nationality");
		}
		if (item->GetFieldValidationStatus("issuingState") != VS_FAILED && item->GetFieldValue("issuingState") != NULL)
		{
			issuer = item->GetFieldValue("issuingState");
		}
		if (item->GetFieldValidationStatus("dateOfBirth") != VS_FAILED && item->GetFieldValue("dateOfBirth") != NULL)
		{
			dateOfBirth = item->GetFieldValue("dateOfBirth");
		}
		if (item->GetFieldValidationStatus("dateOfExpiry") != VS_FAILED && item->GetFieldValue("dateOfExpiry") != NULL)
		{
			dateOfExpiry = item->GetFieldValue("dateOfExpiry");
		}
		if (item->GetFieldValidationStatus("sex") != VS_FAILED && item->GetFieldValue("sex") != NULL)
		{
			gender = item->GetFieldValue("sex");
		}
		if (item->GetFieldValidationStatus("primaryIdentifier") != VS_FAILED && item->GetFieldValue("primaryIdentifier") != NULL)
		{
			surname = item->GetFieldValue("primaryIdentifier");
		}
		if (item->GetFieldValidationStatus("secondaryIdentifier") != VS_FAILED && item->GetFieldValue("secondaryIdentifier") != NULL)
		{
			givenname = item->GetFieldValue("secondaryIdentifier");
		}

		return *this;
	}

	string ToString()
	{
		string msg = "Raw Text:\n";
		for (size_t idx = 0; idx < rawText.size(); ++idx)
		{
			msg += "\tLine " + to_string(idx + 1) + ": " + rawText[idx] + "\n";
		}
		msg += "Parsed Information:\n";
		msg += "\tDocument Type: " + docType + "\n";
		msg += "\tDocument ID: " + docId + "\n";
		msg += "\tSurname: " + surname + "\n";
		msg += "\tGiven Name: " + givenname + "\n";
		msg += "\tNationality: " + nationality + "\n";
		msg += "\tIssuing Country or Organization: " + issuer + "\n";
		msg += "\tGender: " + gender + "\n";
		msg += "\tDate of Birth(YYMMDD): " + dateOfBirth + "\n";
		msg += "\tExpiration Date(YYMMDD): " + dateOfExpiry + "\n";

		return msg;
	}
};

int main(int argc, char *argv[])
{
	printf("*************************************************\r\n");
	printf("Welcome to Dynamsoft MRZ Demo\r\n");
	printf("*************************************************\r\n");
	printf("Hints: Please input 'Q' or 'q' to quit the application.\r\n");

	int iRet = -1;
	char szErrorMsg[256];
	// Initialize license.
	// Request a trial from https://www.dynamsoft.com/customer/license/trialLicense?product=mrz
	iRet = CLicenseManager::InitLicense("DLS2eyJoYW5kc2hha2VDb2RlIjoiMjAwMDAxLTE2NDk4Mjk3OTI2MzUiLCJvcmdhbml6YXRpb25JRCI6IjIwMDAwMSIsInNlc3Npb25QYXNzd29yZCI6IndTcGR6Vm05WDJrcEQ5YUoifQ==", szErrorMsg, 256);
	if (iRet != EC_OK)
	{
		cout << szErrorMsg << endl;
	}
	int errorCode = 1;
	char errorMsg[512] = {0};

	CCaptureVisionRouter *cvr = new CCaptureVisionRouter;
	errorCode = cvr->InitSettingsFromFile("MRZ.json", errorMsg, 512);
	if (errorCode != EC_OK)
	{
		cout << "error:" << errorMsg << endl;
		return -1;
	}

	char pszImageFile[512] = {0};
	bool bExit = false;
	while (1)
	{
		bExit = GetImagePath(pszImageFile);
		if (bExit)
			break;
		float costTime = 0.0;
		int errorCode = 0;

		CCapturedResult *captureResult = cvr->Capture(pszImageFile);
		if (captureResult)
		{
			CParsedResult *parsedResult = captureResult->GetParsedResult();
			if (parsedResult)
			{
				for (int i = 0; i < parsedResult->GetItemsCount(); i++)
				{
					const CParsedResultItem *item = parsedResult->GetItem(i);
					MRZResult result;
					result.FromParsedResultItem(item);
					cout << result.ToString() << endl;
				}
				parsedResult->Release();
			}

			captureResult->Release();
		}
	}

	delete cvr, cvr = NULL;
	return 0;
}