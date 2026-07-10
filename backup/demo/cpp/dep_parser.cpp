#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>


bool parseMakefileDeps(const std::string &depFilePath, const std::string &outputFilePath)
{
    std::ifstream file(depFilePath);
    if (!file.is_open()) {
        std::cerr << "ERROR: cann't open file " << depFilePath << std::endl;
        return false;
    }

    std::string content((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());
    file.close();

    std::regex continuationRegex(R"(\\\s*\n\s*)");
    content = std::regex_replace(content, continuationRegex, " ");
    std::regex depRegex(R"(.*?\s*:\s*(.+))");
    std::smatch match;
    std::vector<std::string> deps;
    if (std::regex_search(content, match, depRegex)) {
        std::string depsStr = match[1].str();
        std::istringstream iss(depsStr);
        std::string dep;
        while (iss >> dep) {
            if (!dep.empty()) {
                deps.push_back(dep);
            }
        }
    }

    std::string targetFile = outputFilePath;
    size_t pos = targetFile.find(".dep.json");
    if (pos != std::string::npos) {
        targetFile.replace(pos, 9, ".o");
    }

    std::ofstream outFile(outputFilePath);
    if (!outFile.is_open()) {
        std::cerr << "ERROR: cann't create output file " << outputFilePath << std::endl;
        return false;
    }

    outFile << "[\n  {\n    \"file\": \"" << targetFile << "\",\n    \"deps\": [";
    for (size_t i = 0; i < deps.size(); ++i) {
        if (i > 0)
            outFile << ",";
        outFile << "\n      \"" << deps[i] << "\"";
    }

    outFile << "\n    ]\n  }\n]\n";
    outFile.close();

    std::cout << "Generated " << outputFilePath << std::endl;
    return true;
}

int main(int argc, char *argv[])
{
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <input.d> <output.dep.json>"
            << std::endl;
        std::cerr << "example: " << argv[0] << " build/main.d build/main.dep.json"
            << std::endl;
        return 1;
    }

    std::string inputFile = argv[1];
    std::string outputFile = argv[2];

    if (!std::filesystem::exists(inputFile)) {
        std::cerr << "ERROR: input file " << inputFile << " not exists" << std::endl;
        return 1;
    }

    return parseMakefileDeps(inputFile, outputFile) ? 0 : 1;
}
