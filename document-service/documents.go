package main

// Document data ported from zero-trust-agent-demo
// document-service/internal/store/documents.go (Apache-2.0, same author).

type Document struct {
	ID                  string   `json:"id"`
	Title               string   `json:"title"`
	Content             string   `json:"content"`
	RequiredDepartment  string   `json:"required_department,omitempty"`
	RequiredDepartments []string `json:"required_departments,omitempty"`
	Sensitivity         string   `json:"sensitivity"`
}

func requiredDepartments(d *Document) []string {
	if len(d.RequiredDepartments) > 0 {
		return d.RequiredDepartments
	}
	if d.RequiredDepartment != "" {
		return []string{d.RequiredDepartment}
	}
	return nil
}

func allDocuments() map[string]*Document {
	return map[string]*Document{
		"DOC-001": {
			ID: "DOC-001", Title: "Engineering Roadmap",
			RequiredDepartment: "engineering", Sensitivity: "medium",
			Content: "# Engineering Roadmap 2026\n\n## Q1 Goals\n- Complete microservices migration\n- Implement Zero Trust architecture\n- Deploy SPIFFE/SPIRE for workload identity\n\n## Q2 Goals\n- Performance optimization\n- Security hardening\n- AI agent integration\n",
		},
		"DOC-002": {
			ID: "DOC-002", Title: "Q4 Financial Report",
			RequiredDepartment: "finance", Sensitivity: "high",
			Content: "# Q4 Financial Report\n\n## Revenue Summary\n- Total Revenue: $12.5M\n- Growth: 23% YoY\n- Recurring Revenue: $8.2M\n",
		},
		"DOC-003": {
			ID: "DOC-003", Title: "Admin Policies",
			RequiredDepartment: "admin", Sensitivity: "critical",
			Content: "# Administrative Policies\n\n## Access Control\n- All access requires MFA\n- Admin credentials rotate every 24 hours\n- Audit logs retained for 7 years\n",
		},
		"DOC-004": {
			ID: "DOC-004", Title: "HR Guidelines",
			RequiredDepartment: "hr", Sensitivity: "medium",
			Content: "# HR Guidelines\n\n## Hiring Process\n1. Job posting approval\n2. Initial screening\n3. Technical assessment\n4. Team interviews\n5. Offer and negotiation\n",
		},
		"DOC-005": {
			ID: "DOC-005", Title: "Budget Projections",
			RequiredDepartments: []string{"finance", "engineering"}, Sensitivity: "high",
			Content: "# Budget Projections 2026\n\n## Engineering Budget\n- Infrastructure: $2.5M\n- Personnel: $8M\n- Tools & Software: $500K\n",
		},
		"DOC-006": {
			ID: "DOC-006", Title: "Compliance Audit",
			RequiredDepartments: []string{"admin", "finance"}, Sensitivity: "critical",
			Content: "# Compliance Audit Report\n\n## SOC 2 Findings\n- All controls effective\n- No exceptions noted\n- Recommendations implemented\n",
		},
		"DOC-007": {
			ID: "DOC-007", Title: "All-Hands Summary",
			RequiredDepartment: "", Sensitivity: "public",
			Content: "# All-Hands Meeting Summary\n\n## Company Updates\n- New product launch successful\n- Customer satisfaction at 95%\n- Team growing to 150 people\n",
		},
	}
}

// Documents returns the documents served by the instance for department:
// every document whose required departments include it. The public
// instance serves only DOC-007.
func Documents(department string) []*Document {
	var out []*Document
	for _, d := range allDocuments() {
		depts := requiredDepartments(d)
		if department == "public" {
			if len(depts) == 0 {
				out = append(out, d)
			}
			continue
		}
		for _, dep := range depts {
			if dep == department {
				out = append(out, d)
				break
			}
		}
	}
	return out
}
