
import os

def test_readme_has_topology():
    readme_path = r'c:\Users\ivanm\Documents\Projects\3x-awg-adg-bundle\readme.md'
    with open(readme_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check if mermaid block exists
    if '```mermaid' not in content:
        print("FAIL: No mermaid block found in README.md")
        return False
    
    # Check for specific nodes from the diagram
    if 'RelayVPS' not in content or 'TargetVPS' not in content:
        print("FAIL: Topology diagram content missing in README.md")
        return False
    
    print("PASS: README contains the topology diagram.")
    return True

if __name__ == "__main__":
    if not test_readme_has_topology():
        exit(1)
