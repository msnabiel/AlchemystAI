#!/bin/bash
# Pre-submission verification script

set -e

echo "========================================="
echo "Pre-Submission Verification"
echo "========================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0

# Check 1: Required files exist
echo "1. Checking required files..."
required_files=(
  "README.md"
  "ARCHITECTURE.md"
  "PRODUCTION_HARDENING.md"
  "deploy.sh"
  "destroy.sh"
  "terraform/main.tf"
  "terraform/compute.tf"
  "terraform/variables.tf"
  "terraform/outputs.tf"
  "scripts/engine-startup.sh"
  "scripts/math-worker-startup.sh"
  "scripts/caller-worker-startup.sh"
  "scripts/api-gateway-startup.sh"
)

for file in "${required_files[@]}"; do
  if [ -f "$file" ]; then
    echo -e "  ${GREEN}✓${NC} $file"
  else
    echo -e "  ${RED}✗${NC} $file (MISSING)"
    ((errors++))
  fi
done
echo ""

# Check 2: Scripts are executable
echo "2. Checking script permissions..."
scripts=("deploy.sh" "destroy.sh")
for script in "${scripts[@]}"; do
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}✓${NC} $script is executable"
  else
    echo -e "  ${YELLOW}⚠${NC} $script is not executable (run: chmod +x $script)"
    ((warnings++))
  fi
done
echo ""

# Check 3: No sensitive data
echo "3. Scanning for sensitive data..."
sensitive_patterns=("API_KEY" "SECRET" "PASSWORD" "private_key" "credentials.json")
found_sensitive=false

for pattern in "${sensitive_patterns[@]}"; do
  if grep -r "$pattern" . --exclude-dir={.git,node_modules,quickstart,.terraform} --exclude="verify.sh" --exclude="PRODUCTION_HARDENING.md" -q 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} Found '$pattern' in codebase - verify it's not a real secret"
    ((warnings++))
    found_sensitive=true
  fi
done

if [ "$found_sensitive" = false ]; then
  echo -e "  ${GREEN}✓${NC} No obvious secrets found"
fi
echo ""

# Check 4: Terraform validation
echo "4. Validating Terraform configuration..."
if command -v terraform &> /dev/null; then
  cd terraform

  # Initialize (quietly)
  if terraform init -upgrade > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Terraform init successful"
  else
    echo -e "  ${RED}✗${NC} Terraform init failed"
    ((errors++))
  fi

  # Validate
  if terraform validate > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Terraform configuration is valid"
  else
    echo -e "  ${RED}✗${NC} Terraform validation failed"
    terraform validate
    ((errors++))
  fi

  # Format check
  if terraform fmt -check > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Terraform files are formatted correctly"
  else
    echo -e "  ${YELLOW}⚠${NC} Terraform files need formatting (run: terraform fmt)"
    ((warnings++))
  fi

  cd ..
else
  echo -e "  ${YELLOW}⚠${NC} Terraform not installed - skipping validation"
  ((warnings++))
fi
echo ""

# Check 5: Documentation completeness
echo "5. Checking documentation..."

# Check README has curl command
if grep -q "curl -X POST" README.md; then
  echo -e "  ${GREEN}✓${NC} README contains curl command example"
else
  echo -e "  ${RED}✗${NC} README missing curl command example"
  ((errors++))
fi

# Check README has architecture diagram
if grep -q "\[API Gateway VM\]" README.md; then
  echo -e "  ${GREEN}✓${NC} README contains architecture diagram"
else
  echo -e "  ${YELLOW}⚠${NC} README might be missing architecture diagram"
  ((warnings++))
fi

# Check for placeholder text in author section (not in code examples)
if grep -A5 "^## Author" README.md | grep -q "<your-email>\|yourusername"; then
  echo -e "  ${YELLOW}⚠${NC} README Author section contains placeholder text - update before submitting!"
  ((warnings++))
fi

# Check PRODUCTION_HARDENING.md has required sections
if grep -q "Production Hardening" PRODUCTION_HARDENING.md && \
   grep -q "100x" PRODUCTION_HARDENING.md; then
  echo -e "  ${GREEN}✓${NC} PRODUCTION_HARDENING.md has required sections"
else
  echo -e "  ${RED}✗${NC} PRODUCTION_HARDENING.md incomplete"
  ((errors++))
fi
echo ""

# Check 6: Startup scripts have shebangs
echo "6. Checking startup scripts..."
for script in scripts/*.sh; do
  if head -n1 "$script" | grep -q "^#!/bin/bash"; then
    echo -e "  ${GREEN}✓${NC} $script has proper shebang"
  else
    echo -e "  ${RED}✗${NC} $script missing #!/bin/bash shebang"
    ((errors++))
  fi
done
echo ""

# Check 7: .gitignore exists and covers essentials
echo "7. Checking .gitignore..."
if [ -f ".gitignore" ]; then
  echo -e "  ${GREEN}✓${NC} .gitignore exists"

  essential_ignores=("*.tfstate" ".terraform/" "*.tfvars")
  for pattern in "${essential_ignores[@]}"; do
    if grep -q "$pattern" .gitignore; then
      echo -e "  ${GREEN}✓${NC} .gitignore includes $pattern"
    else
      echo -e "  ${YELLOW}⚠${NC} .gitignore missing $pattern"
      ((warnings++))
    fi
  done
else
  echo -e "  ${RED}✗${NC} .gitignore missing"
  ((errors++))
fi
echo ""

# Summary
echo "========================================="
echo "Verification Summary"
echo "========================================="

if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed!${NC}"
  echo ""
  echo "Your submission is ready. Next steps:"
  echo "1. Review README.md and update placeholder text"
  echo "2. Create git repository or tarball"
  echo "3. Submit via email to anuran@getalchemystai.com"
  exit 0
elif [ $errors -eq 0 ]; then
  echo -e "${YELLOW}⚠ $warnings warning(s) found${NC}"
  echo ""
  echo "Warnings are non-critical but should be addressed before submission."
  echo "Review the output above and fix any issues."
  exit 0
else
  echo -e "${RED}✗ $errors error(s) found${NC}"
  echo -e "${YELLOW}⚠ $warnings warning(s) found${NC}"
  echo ""
  echo "Please fix the errors above before submitting."
  exit 1
fi
